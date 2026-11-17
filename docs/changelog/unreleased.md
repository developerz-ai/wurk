# Unreleased

### Fixed

- **The demo lock is off the puma reactor advisories.** `demo/Gemfile.lock` moves puma from 8.0.2 to 8.1.2, above the `>= 8.0.3` floor for GHSA-m5xw-3hrw-qcmf (a reactor timeout queue that loses order, letting a slow client keep other connections open past their timeout), GHSA-xw3h-pgr9-3vg7 and GHSA-jm4r-w4xx-qxw7. The demo image installs the lock frozen, so this is what it ships; puma's only runtime dependency, `nio4r`, is unchanged.
