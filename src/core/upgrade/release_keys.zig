//! Minisign public keys that sign pf release archives.
//!
//! Each value is the base64 line of a `minisign.pub` file. `active` signs every
//! release; `next` stays empty until a rotation, when it holds the replacement
//! key so builds that trust both can install releases signed by either.
//! `scripts/sign-release-archives.sh` verifies each archive against `active`
//! before anything is published.

pub const active = "RWQWFhzsm1qpo3kPbJvq8xfZbp/5exhWN+twewvsmw5AAEoH/7agOJhr";
pub const next = "";
