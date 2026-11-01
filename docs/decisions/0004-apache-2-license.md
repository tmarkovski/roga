# 4. License yaga under Apache 2.0

Accepted on 2026-11-01.

## Context

yaga is free and open source. We want anyone to be able to use, change, and build on it, and we want contributors to grant patent rights along with their code, so that nobody can contribute code and later assert patents against people who use it.

## Decision

yaga is licensed under the Apache License, Version 2.0. The full text is in [LICENSE](../../LICENSE).

## Consequences

- Contributions are accepted under the same license. Section 5 of the license covers this, so we don't need a separate contributor agreement.
- Dependencies must have licenses that are compatible with Apache 2.0. Permissive licenses such as MIT and BSD are fine, but code licensed only under the GPL can't be included. libgit2 is licensed under GPLv2 with a linking exception, which allows linking it into yaga if we decide to use it.
- Anyone, including companies building closed products, may reuse yaga's code as long as they keep the license and notices.
