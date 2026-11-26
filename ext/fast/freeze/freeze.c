#include <ruby.h>
#include <string.h>

/*
 * How deep the walk goes on the C stack. A container nested deeper than this
 * is put aside and opened afterwards from the top, so a value of any depth is
 * frozen without the walk outgrowing the stack of the thread or fiber it runs
 * on. A level costs up to about 530 bytes of stack (measured on arm64, a Hash
 * reached through a key), so this many come to under 70 KB.
 */
#define MAX_RECURSION 128

/*
 * The record of what one call has opened lives on the C stack until it holds
 * SEEN_INLINE_MAX objects, then moves to an identity Hash. SEEN_SLOTS must be
 * a power of two.
 */
#define SEEN_SLOTS 128
#define SEEN_INLINE_MAX 96

static ID id_freeze;
static ID id_compare_by_identity;
static VALUE cData;

struct walk {
    int trust_frozen;
    int recurse_into_structs;
    int seen_count;      /* objects in seen_inline; -1 until the record is first used */
    VALUE seen_table;    /* the identity Hash, once seen_inline is full */
    VALUE deferred;      /* an Array of the containers put aside at MAX_RECURSION */
    VALUE seen_inline[SEEN_SLOTS];
};

struct level {
    struct walk *w;
    int depth;
};

static void visit(struct walk *w, VALUE v, int depth);

/* ---- the record of what this call has opened ---- */

static inline unsigned
seen_slot(VALUE v)
{
    /* Objects are aligned, so the low bits of an address say nothing. */
    size_t h = (size_t)v >> 3;
    h ^= h >> 7;
    h ^= h >> 14;
    return (unsigned)(h & (SEEN_SLOTS - 1));
}

/*
 * Records an object, and says whether it was recorded already.
 *
 * The objects in seen_inline are found by the garbage collector's scan of the
 * C stack, which keeps each one alive and at its address. The identity Hash
 * does the same for its keys. Neither holds an address that could come to
 * mean a different object during the call.
 */
static int
seen(struct walk *w, VALUE v)
{
    unsigned i;

    if (w->seen_table != Qfalse) {
        if (rb_hash_lookup2(w->seen_table, v, Qfalse) != Qfalse) return 1;
        rb_hash_aset(w->seen_table, v, Qtrue);
        return 0;
    }

    if (w->seen_count < 0) {
        memset(w->seen_inline, 0, sizeof(w->seen_inline));
        w->seen_count = 0;
    }

    for (i = seen_slot(v); w->seen_inline[i]; i = (i + 1) & (SEEN_SLOTS - 1)) {
        if (w->seen_inline[i] == v) return 1;
    }

    if (w->seen_count == SEEN_INLINE_MAX) {
        w->seen_table = rb_funcallv(rb_hash_new(), id_compare_by_identity, 0, 0);
        for (i = 0; i < SEEN_SLOTS; i++) {
            if (w->seen_inline[i]) rb_hash_aset(w->seen_table, w->seen_inline[i], Qtrue);
        }
        rb_hash_aset(w->seen_table, v, Qtrue);
        return 0;
    }

    w->seen_inline[i] = v;
    w->seen_count++;
    return 0;
}

/* ---- freezing one object ---- */

/* Calls the object's own freeze. A BasicObject has none, and is frozen directly. */
static void
call_freeze(VALUE v)
{
    if (rb_check_funcall(v, id_freeze, 0, 0) == Qundef) rb_obj_freeze(v);
}

/*
 * A plain String, Array or Hash is frozen here without a method call. A
 * subclass, or an object with a singleton class, has its own freeze called.
 */
static void
freeze_string(VALUE v)
{
    if (RBASIC_CLASS(v) == rb_cString) rb_str_freeze(v);
    else call_freeze(v);
}

static void
freeze_array(VALUE v)
{
    if (RBASIC_CLASS(v) == rb_cArray) rb_ary_freeze(v);
    else call_freeze(v);
}

static void
freeze_hash(VALUE v)
{
    if (RBASIC_CLASS(v) == rb_cHash) rb_hash_freeze(v);
    else call_freeze(v);
}

static void
freeze_object(VALUE v)
{
    if (!RB_OBJ_FROZEN_RAW(v)) call_freeze(v);
}

/* ---- what counts as a container ---- */

/* A Range is laid out as a struct too, and is not one. */
static int
is_struct(VALUE v)
{
    return RTEST(rb_obj_is_kind_of(v, cData)) || RTEST(rb_obj_is_kind_of(v, rb_cStruct));
}

static int
is_set(VALUE v)
{
    return RTEST(rb_obj_is_kind_of(v, rb_cSet));
}

/*
 * Whether to open a container that has just been found and, if it was not
 * frozen, has just had its freeze called.
 *
 * A container found frozen is opened once per call at most, and not at all
 * when frozen containers are trusted. One this call froze is not recorded,
 * so a value that shares nothing never touches the record; if such a
 * container is reached a second time it is found frozen, recorded then, and
 * opened once more. That keeps the walk linear in the size of the value
 * whatever it shares, and makes a cycle end.
 */
static int
should_open(struct walk *w, VALUE v, int was_frozen, int trust)
{
    if (was_frozen) return !trust && !seen(w, v);

    /* Its own freeze left it unfrozen, so only the record can stop a second visit. */
    if (!RB_OBJ_FROZEN_RAW(v)) return !seen(w, v);

    return 1;
}

/* ---- opening a container ---- */

static int
hash_entry(VALUE key, VALUE value, VALUE arg)
{
    struct level *level = (struct level *)arg;

    visit(level->w, key, level->depth);
    visit(level->w, value, level->depth);
    return ST_CONTINUE;
}

static int
set_element(VALUE element, VALUE arg)
{
    struct level *level = (struct level *)arg;

    visit(level->w, element, level->depth);
    return ST_CONTINUE;
}

/* Walks what an Array, a Hash, a Set, a Data or a Struct holds. */
static void
walk_into(struct walk *w, VALUE v, int depth)
{
    struct level level;
    long i, n;

    if (depth > MAX_RECURSION) {
        if (w->deferred == Qfalse) w->deferred = rb_ary_new();
        rb_ary_push(w->deferred, v);
        return;
    }

    level.w = w;
    level.depth = depth;

    switch (RB_BUILTIN_TYPE(v)) {
      case T_ARRAY:
        /* The length is read again each time: a freeze called below may run any code. */
        for (i = 0; i < RARRAY_LEN(v); i++) visit(w, RARRAY_AREF(v, i), depth);
        break;

      case T_HASH:
        rb_hash_foreach(v, hash_entry, (VALUE)&level);
        break;

      case T_STRUCT:
        n = RSTRUCT_LEN(v);
        for (i = 0; i < n; i++) visit(w, RSTRUCT_GET(v, (int)i), depth);
        break;

      default:
        rb_set_foreach(v, set_element, (VALUE)&level);
        break;
    }

    RB_GC_GUARD(v);
}

/* Freezes one value found during the walk, and opens it if it is a container. */
static void
visit(struct walk *w, VALUE v, int depth)
{
    int frozen;

    if (RB_SPECIAL_CONST_P(v)) return;

    frozen = RB_OBJ_FROZEN_RAW(v) ? 1 : 0;

    switch (RB_BUILTIN_TYPE(v)) {
      case T_STRING:
        if (!frozen) freeze_string(v);
        return;

      case T_ARRAY:
        if (!frozen) freeze_array(v);
        if (!should_open(w, v, frozen, w->trust_frozen)) return;
        break;

      case T_HASH:
        if (!frozen) freeze_hash(v);
        if (!should_open(w, v, frozen, w->trust_frozen)) return;
        break;

      case T_STRUCT:
        if (!frozen) call_freeze(v);
        if (!w->recurse_into_structs || !is_struct(v)) return;
        /* A Data is always found frozen, so trust has no say over a struct. */
        if (!should_open(w, v, frozen, 0)) return;
        break;

      case T_CLASS:
      case T_MODULE:
        return;

      case T_OBJECT:
      case T_DATA:
        if (is_set(v)) {
            if (!frozen) call_freeze(v);
            if (!should_open(w, v, frozen, w->trust_frozen)) return;
            break;
        }
        /* fall through */

      default:
        if (!frozen) call_freeze(v);
        return;
    }

    walk_into(w, v, depth + 1);
}

/*
 * Fast::Freeze.__deep_freeze__(value, trust_frozen, recurse_into_structs)
 *
 * The flags are positional here because a keyword argument read in C costs
 * two objects a call. Fast::Freeze.deep_freeze reads them as keywords in Ruby,
 * which costs none, and passes them on.
 */
static VALUE
ff_deep_freeze(VALUE mod, VALUE value, VALUE trust_frozen, VALUE recurse_into_structs)
{
    struct walk w;

    w.trust_frozen = RTEST(trust_frozen);
    w.recurse_into_structs = RTEST(recurse_into_structs);
    w.seen_count = -1;
    w.seen_table = Qfalse;
    w.deferred = Qfalse;

    if (!RB_SPECIAL_CONST_P(value) && RB_BUILTIN_TYPE(value) == T_STRUCT && is_struct(value)) {
        /* A Data or a Struct passed in is always opened, frozen or not. */
        freeze_object(value);
        if (w.recurse_into_structs) seen(&w, value);
        walk_into(&w, value, 1);
    }
    else {
        visit(&w, value, 0);
    }

    while (w.deferred != Qfalse && RARRAY_LEN(w.deferred) > 0) {
        walk_into(&w, rb_ary_pop(w.deferred), 1);
    }

    return value;
}

void
Init_freeze(void)
{
    VALUE mFast, mFreeze;

    rb_ext_ractor_safe(true);

    id_freeze = rb_intern("freeze");
    id_compare_by_identity = rb_intern("compare_by_identity");

    cData = rb_path2class("Data");
    rb_gc_register_mark_object(cData);

    mFast = rb_define_module("Fast");
    mFreeze = rb_define_module_under(mFast, "Freeze");
    rb_define_private_method(rb_singleton_class(mFreeze), "__deep_freeze__", ff_deep_freeze, 3);
}
