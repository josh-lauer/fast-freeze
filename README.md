# fast-freeze

Deep freeze for Ruby values, written in C.

`Fast::Freeze.deep_freeze(value)` freezes a value and what it holds. It is one method. It adds nothing to `Object` or any other class, and it allocates nothing.

```ruby
require "fast/freeze"

config = { "hosts" => ["a.example", "b.example"], "retry" => { "limit" => 3 } }
Fast::Freeze.deep_freeze(config)

config["hosts"] << "c.example"         # FrozenError
config["retry"]["limit"] = 5           # FrozenError
config["hosts"][0] << ".test"          # FrozenError
```

## Install

```ruby
gem "fast-freeze"
```

It needs Ruby 4.0 or later.

Precompiled gems are published for Linux on x86-64 and arm64, with glibc or musl, and for macOS on Apple silicon. On any other platform the gem compiles a small C extension when it is installed, which needs a C compiler.

## What it freezes

| Found in the value | What happens |
|---|---|
| `nil`, `true`, `false`, a number, a Symbol | Nothing. It is frozen by nature. |
| A String | Frozen. |
| An Array | Frozen, and so is each element. |
| A Hash | Frozen, and so are each key and each value. |
| A Set | Frozen, and so is each element. |
| A class or a module | Left alone. |
| Any other object | `freeze` is called on it. It is not looked inside. |

The same rules apply to each element, key and value, so containers inside containers are frozen however deeply they nest.

A `Data` or a `Struct` is treated by where it is:

- **Passed to `deep_freeze`**, it is frozen, and so is what each of its members holds. A `Data` is frozen from birth while the things it holds are not, and this is how you freeze those.
- **Found inside the value**, it is frozen and not looked inside, like any other object. `recurse_into_structs: true` changes that.

```ruby
Point = Data.define(:name, :tags)

point = Point.new(name: +"origin", tags: [+"a"])
Fast::Freeze.deep_freeze(point)

point.name.frozen?    # => true
point.tags.frozen?    # => true
```

Members are read from the object itself, not through its reader methods, so a reader that has been redefined changes nothing.

`deep_freeze` returns the value it was given.

## Options

### `trust_frozen:` (default `false`)

Whether a container found already frozen is taken to be frozen all the way down.

```ruby
inner = +"text"
list = [inner].freeze

Fast::Freeze.deep_freeze(list, trust_frozen: true)   # returns at once
inner.frozen?                                        # => false

Fast::Freeze.deep_freeze(list)                       # freezes what is inside
inner.frozen?                                        # => true
```

By default a frozen container is treated like any other and its contents are frozen too, so one that someone froze by hand without freezing its contents is frozen through. Pass `true` when every frozen container in the value is known to be frozen all the way down, such as one `deep_freeze` froze before: passing it again then costs one check.

The option applies to an Array, a Hash and a Set. It does not apply to a `Data` or a `Struct` passed to `deep_freeze`, whose members are always frozen.

### `recurse_into_structs:` (default `false`)

Whether what the members of every `Data` and `Struct` found inside the value hold is frozen too.

```ruby
Line = Struct.new(:text)

page = [Line.new(+"first")]
Fast::Freeze.deep_freeze(page)
page[0].frozen?         # => true
page[0].text.frozen?    # => false

page = [Line.new(+"first")]
Fast::Freeze.deep_freeze(page, recurse_into_structs: true)
page[0].text.frozen?    # => true
```

With this option a `Data` or a `Struct` found inside is looked inside whether or not it was already frozen. A `Data` is always frozen, so skipping the frozen ones would make the option do nothing.

The two options are separate. With `trust_frozen: true` a frozen Array is passed over, along with any struct inside it.

## What it does not reach

- **Inside any other object.** An object that is not one of the containers above has `freeze` called and nothing more. What its instance variables hold is left as it is. If a class of yours holds things that should freeze with it, define `freeze` on the class to freeze them; `deep_freeze` calls it.
- **The default value of a Hash.** After `Fast::Freeze.deep_freeze(Hash.new([]))` the Hash is frozen and the Array it hands out for a missing key is not.
- **The ends of a Range.** A Range is frozen and not looked inside.
- **What a Proc or a Method can reach.** A Proc is frozen. What the variables it closes over hold is left as it is.

## What you can rely on

- **Subclasses keep their own `freeze`.** A plain String, Array or Hash is frozen directly in C. A subclass of one, or an object with a singleton class, has its `freeze` method called.
- **Shared objects cost once.** A container reached by many paths is looked inside at most twice, never once per path. The work grows with the size of the value, whatever it shares.
- **Cycles end.** A value that holds itself is frozen and the call returns, with every combination of options.
- **Any depth.** Nesting does not raise or overflow the stack, on a thread or on a fiber. Past 128 levels it keeps a list of the containers still to do and works through that, instead of going deeper on the stack.
- **No allocation.** A call allocates no objects. The exceptions are rare: nesting past 128 levels, and a call that looks inside more than 96 containers or structs that were already frozen.
- **Errors pass through.** If a `freeze` raises, the error reaches the caller. Whatever was frozen before it stays frozen.

## Speed

Nanoseconds for one call, on Ruby 4.0.7 with YJIT on an Apple silicon laptop. `bundle exec rake benchmark` runs it on yours.

| Value | fast-freeze | The same rules in plain Ruby | `Ractor.make_shareable` | ice_nine `deep_freeze!` |
|---|---|---|---|---|
| Small nested value (4 containers, 1 String) | 81 | 254 | 195 | 457 |
| Document of about 90 objects | 740 | 2,571 | 2,760 | 5,206 |
| Array of 1,000 such documents | 643,550 | 2,515,650 | 3,014,750 | 5,162,250 |
| Document that is already frozen | 533 | 2,253 | 1,898 | 59 |
| `Data` with 16 members | 169 | 937 | 407 | 102, and freezes nothing inside it |

These do not all do the same work, so read the table as how fast each one is at its own idea of a deep freeze:

- **ice_nine** also freezes what the instance variables of every object hold, and it does not look inside a `Data`. `deep_freeze!` is its variant that skips what is already frozen, which is why it passes the frozen document at once. Plain `deep_freeze` goes through everything again, frozen or not, and is slower on every row.
- **`Ractor.make_shareable`** also freezes what instance variables hold, and raises on a value that cannot be shared between Ractors.
- **The plain Ruby version** follows the same rules as `deep_freeze` with its defaults. It is in `benchmark/compare.rb`, where it is labelled "walk in Ruby".

With `trust_frozen: true` fast-freeze skips the frozen document too, in 56 ns. The other rows are unchanged by it.

## Development

```
bundle install
bundle exec rake                        # compile, then run the specs
GC_STRESS=true bundle exec rake spec    # the same, with a collection at every allocation
bundle exec rake benchmark
```

CI runs both spec commands on Linux, macOS and Windows.

## Releasing

Pushing a tag named for the version, such as `v0.1.0`, runs the release workflow. It builds the source gem and one precompiled gem for each platform, installs each precompiled gem on its own platform and runs it, and then publishes them all to RubyGems.

- Set `Fast::Freeze::VERSION` and add the version to `CHANGELOG.md` first. The workflow refuses a tag that does not match the version.
- Running the workflow by hand from the Actions tab builds and verifies the gems and publishes nothing.
- If publishing fails partway, run the failed job again. It skips the gems RubyGems already has and pushes the rest.
- Publishing uses RubyGems trusted publishing, so the repository holds no API key. RubyGems must list this repository and `release.yml` as a trusted publisher for the gem.
- `bundle exec rake gem:x86_64-linux-gnu` builds one precompiled gem locally. It needs Docker.

## Licence

MIT. See `LICENSE.txt`.
