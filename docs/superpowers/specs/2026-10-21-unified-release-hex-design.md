# Shared application versions and Hex releases

The root Mix project and every `apps/*/mix.exs` use one release version. Keep
version literals in child projects so Hex archives remain self-contained. The
root version is the development checkout's reference; the release input stamps
the root and all children for that release. Discover children dynamically and
reject malformed versions or unsupported declarations before modifying files.
CI checks version parity without starting umbrella applications.
The general updater accepts SemVer; product release preparation additionally
requires a Docker-compatible `v<version>` tag of at most 128 characters and
rejects build metadata before any source or tag mutation.

Only projects declaring `package:` opt into Hex publication. Preserve the
existing nine opt-ins and add `gsmlg_aws`, required by telemetry and socket.
Complete missing package assets using the existing MIT convention, retaining
TOML's existing Apache-2.0/MIT notices. Internal package dependencies specify
the same exact release version while retaining `in_umbrella: true` locally.
Unmarked applications remain application-only projects.

The release workflow prepares one versioned source commit and tag from the
requested revision. All build jobs use that immutable commit. A tag retry must
match the prepared source tree; conflicting tags are errors. No force-pushing
or implicit development-branch reset is needed.

Build and validate every opted-in Hex archive before publishing any package.
Validate versions, distributable assets and the internal dependency closure;
publish dependencies before dependants. Publishing requires `HEX_API_KEY` and
uses the regular Hex CLI. A retry accepts an already-published version only
when its downloaded archive matches the built candidate. Other network or
publication failures stop the job. Create the GitHub release only after all
artifact builds and Hex publication succeed. Preserve existing release targets
and registry credentials. Serialize release runs without cancelling a running
publication.

Validation covers the version updater in temporary repositories, dependency
ordering and invalid package graphs, publication retry behavior with controlled
commands, real archive metadata and fresh external archive consumers. Run only
tests and formatting relevant to these release changes. This task updates the
automation; it does not choose or dispatch a new product release.
