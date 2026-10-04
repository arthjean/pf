/**
 * Fake pf release channel for upgrade tests.
 *
 * Each server signs its archives with a minisign key generated for that run.
 * pf trusts the key through PF_E2E_UPGRADE_PUBLIC_KEY, which it honors only
 * together with a loopback PF_E2E_UPGRADE_BASE_URL.
 */
import { createHash, generateKeyPairSync, randomBytes, sign, type KeyObject } from "node:crypto";
import { chmodSync, copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { deflateRawSync } from "node:zlib";
import { PF_BIN } from "../evals/eval-helpers";

export type UpgradeFixtureOptions = {
  /** Dev build commit served by `dev.json`. */
  revision?: string;
  /** Contents of `latest.txt`, a release tag; null serves a 404, as before the first release. */
  latest?: string | null;
  /** `bad` flips one archive byte after signing; `missing` serves no `.minisig`. */
  signature?: "valid" | "bad" | "missing";
  /** Version named by the trusted comment, when it must differ from `latest`. */
  signedVersion?: string;
  /** Redirects the archive request to another host. */
  redirectArchive?: boolean;
};

export type UpgradeFixture = {
  baseUrl: string;
  /** Bytes pf installs when the upgrade succeeds. */
  artifact: Buffer;
  /** Environment that points pf at this server and trusts its key. */
  env: { PF_E2E_UPGRADE_BASE_URL: string; PF_E2E_UPGRADE_PUBLIC_KEY: string };
  stop: () => void;
};

export function upgradePlatform(): string {
  if (process.platform === "win32") return "windows-x86_64";
  const os = process.platform === "darwin" ? "macos" : "linux";
  return `${os}-${process.arch === "arm64" ? "aarch64" : "x86_64"}`;
}

export function upgradeArchiveName(): string {
  return `pf-${upgradePlatform()}${process.platform === "win32" ? ".zip" : ".tar.gz"}`;
}

/** A minisign key pair: `ED` signatures, a random key id. */
class MinisignKey {
  private readonly privateKey: KeyObject;
  private readonly keyId = randomBytes(8);
  readonly publicKey: string;

  constructor() {
    const pair = generateKeyPairSync("ed25519");
    this.privateKey = pair.privateKey;
    const raw = Buffer.from(pair.publicKey.export({ format: "jwk" }).x!, "base64url");
    this.publicKey = Buffer.concat([Buffer.from("Ed"), this.keyId, raw]).toString("base64");
  }

  sign(data: Buffer, trustedComment: string): string {
    const digest = new Bun.CryptoHasher("blake2b512").update(data).digest();
    const signature = sign(null, digest, this.privateKey);
    const global = sign(null, Buffer.concat([signature, Buffer.from(trustedComment)]), this.privateKey);
    return [
      "untrusted comment: signature from pf e2e test key",
      Buffer.concat([Buffer.from("ED"), this.keyId, signature]).toString("base64"),
      `trusted comment: ${trustedComment}`,
      global.toString("base64"),
      "",
    ].join("\n");
  }
}

/** A zip with one deflated entry, as PowerShell's Compress-Archive writes. */
function zipOne(name: string, data: Buffer): Buffer {
  const compressed = deflateRawSync(data);
  const nameBytes = Buffer.from(name);
  const crc = Bun.hash.crc32(data);
  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4);
  local.writeUInt16LE(8, 8);
  local.writeUInt32LE(crc, 14);
  local.writeUInt32LE(compressed.length, 18);
  local.writeUInt32LE(data.length, 22);
  local.writeUInt16LE(nameBytes.length, 26);
  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50, 0);
  central.writeUInt16LE(20, 4);
  central.writeUInt16LE(20, 6);
  central.writeUInt16LE(8, 10);
  central.writeUInt32LE(crc, 16);
  central.writeUInt32LE(compressed.length, 20);
  central.writeUInt32LE(data.length, 24);
  central.writeUInt16LE(nameBytes.length, 28);
  const centralOffset = local.length + nameBytes.length + compressed.length;
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(1, 8);
  end.writeUInt16LE(1, 10);
  end.writeUInt32LE(central.length + nameBytes.length, 12);
  end.writeUInt32LE(centralOffset, 16);
  return Buffer.concat([local, nameBytes, compressed, central, nameBytes, end]);
}

// The "new" artifact on POSIX is a wrapper script that logs its argv to
// argvLogPath and execs the real PF_BIN, so upgrade relaunch tests can drive
// the handoff without shipping a second binary. Windows cannot run a script
// as pf.exe, so its artifact is PF_BIN with a marker appended.
function buildArchive(root: string, argvLogPath: string): { artifact: Buffer; archive: Buffer } {
  const artifactDir = join(root, "release-artifact");
  mkdirSync(artifactDir, { recursive: true });
  if (process.platform === "win32") {
    // Trailing bytes after the PE image leave it runnable and tell the
    // installed artifact apart from the binary it replaced.
    const artifact = Buffer.concat([readFileSync(PF_BIN), Buffer.from("\npf-e2e-upgrade-artifact\n")]);
    return { artifact, archive: zipOne("pf.exe", artifact) };
  }
  const wrapperPath = join(artifactDir, "pf");
  const script = `#!/bin/sh
{
  printf '%s' "$0"
  for arg in "$@"; do
    printf '\\t%s' "$arg"
  done
  printf '\\n'
} >> ${shellQuote(argvLogPath)}
exec ${shellQuote(PF_BIN)} "$@"
`;
  writeFileSync(wrapperPath, script);
  chmodSync(wrapperPath, 0o755);
  const archivePath = join(root, "pf.tar.gz");
  const tar = Bun.spawnSync(["tar", "-czf", archivePath, "-C", artifactDir, "pf"]);
  if (tar.exitCode !== 0) throw new Error(tar.stderr.toString());
  return { artifact: Buffer.from(script), archive: readFileSync(archivePath) };
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

export function startUpgradeServer(
  root: string,
  argvLogPath: string,
  options: UpgradeFixtureOptions = {},
): UpgradeFixture {
  const { artifact, archive } = buildArchive(root, argvLogPath);
  const name = upgradeArchiveName();
  const published = options.latest !== null;
  const latest = options.latest ?? "v9.9.9";
  const revision = options.revision ?? "abcdef0123456789abcdef0123456789abcdef01";
  const key = new MinisignKey();
  const signing = options.signature ?? "valid";

  const served = Buffer.from(archive);
  if (signing === "bad") served[served.length - 1] ^= 0xff;
  const checksum = createHash("sha256").update(served).digest("hex");
  const stableSignature = key.sign(
    archive,
    `file:${name} version:${options.signedVersion ?? latest} channel:stable`,
  );
  const devSignature = key.sign(archive, `file:${name} version:9.9.9 channel:dev commit:${revision}`);

  const stableArchiveRoute = `/${latest}/${name}`;
  const devArchiveRoute = `/dev/${revision}/${name}`;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      const path = url.pathname;
      if (path === "/latest.txt" && published) return new Response(`${latest}\n`);
      if (path === "/dev.json") {
        return Response.json({ version: "9.9.9", commit: revision });
      }
      if (path === stableArchiveRoute || path === devArchiveRoute) {
        if (options.redirectArchive) {
          return Response.redirect(`http://localhost:${url.port}/elsewhere/${name}`, 302);
        }
        return new Response(served);
      }
      if (path === `/elsewhere/${name}`) return new Response(served);
      if (path === `${stableArchiveRoute}.sha256` || path === `${devArchiveRoute}.sha256`) {
        return new Response(`${checksum}  ${name}\n`);
      }
      if (signing !== "missing") {
        if (path === `${stableArchiveRoute}.minisig`) return new Response(stableSignature);
        if (path === `${devArchiveRoute}.minisig`) return new Response(devSignature);
      }
      return new Response("not found", { status: 404 });
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}`;
  return {
    baseUrl,
    artifact,
    env: { PF_E2E_UPGRADE_BASE_URL: baseUrl, PF_E2E_UPGRADE_PUBLIC_KEY: key.publicKey },
    stop: () => server.stop(true),
  };
}

/** Copies the built binary to `dir` under the platform's binary name. */
export function installPfCopy(dir: string): string {
  const path = join(dir, process.platform === "win32" ? "pf.exe" : "pf");
  copyFileSync(PF_BIN, path);
  chmodSync(path, 0o755);
  return path;
}
