# GFWList parser fixtures

`official.txt` is an unmodified copy of the official GFWList payload.

- Source: https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt
- Retrieved: 2026-07-23
- SHA-256: `22319f2a1dc096ef57af499f384138eae1842db1f85c28d60530b8abed805985`
- Upstream license: https://github.com/gfwlist/gfwlist/blob/master/LICENSE

It was retrieved with the exact command recorded in the implementation plan and
must not be edited locally.

`supported.txt` is synthetic test data, not upstream content. It is the Base64
encoding of a small Adblock document covering comments, metadata, proxy and
exception rules, a plain domain, a whole-host URL, path and regular-expression
rules, a modifier, a wildcard, a malformed domain, and a Unicode domain. To
regenerate it, decode and review the current document, make the smallest intended
change, Base64-encode the complete UTF-8 document with 76-column wrapping, then
review both the decoded diff and the parser expectations before committing.
