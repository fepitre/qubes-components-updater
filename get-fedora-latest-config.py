#!/usr/bin/env python3
import argparse
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

import koji
from packaging.version import Version

KOJI_HUB = "https://koji.fedoraproject.org/kojihub"
KOJI_TOPURL = "https://kojipkgs.fedoraproject.org"
KEY_NAME_RE = re.compile(r"^RPM-GPG-KEY-fedora-(\d+)-primary$")
DOWNLOAD_TIMEOUT = 300


def load_signing_keys(keysdir):
    keys = {}
    releases = set()
    for key_file in sorted(keysdir.iterdir()):
        match = KEY_NAME_RE.match(key_file.name)
        if not match:
            continue
        releases.add(int(match.group(1)))
        result = subprocess.run(
            ["gpg", "--with-colons", "--show-keys", str(key_file)],
            capture_output=True,
            text=True,
            check=True,
        )
        for line in result.stdout.splitlines():
            fields = line.split(":")
            if fields[0] in ("pub", "sub") and len(fields[4]) >= 8:
                keys[fields[4][-8:].lower()] = key_file
    return keys, sorted(releases, reverse=True)


def tags_for_release(release, include_testing):
    tags = [f"f{release}", f"f{release}-updates"]
    if include_testing:
        tags.append(f"f{release}-updates-testing")
    return tags


def is_rc(build):
    return "rc" in build["release"].lower()


def build_sort_key(build):
    return (Version(build["version"]), build["build_id"])


def kernel_builds_by_release(session, releases, include_testing):
    tags = [
        (release, tag)
        for release in releases
        for tag in tags_for_release(release, include_testing)
    ]
    with session.multicall(strict=False) as multicall:
        calls = [
            (release, multicall.listTagged(tag, package="kernel"))
            for release, tag in tags
        ]
    builds = {}
    for release, call in calls:
        try:
            tagged = call.result
        except koji.GenericError:
            # Tag does not exist for that release, nothing to collect.
            continue
        builds.setdefault(release, []).extend(tagged)
    return builds


def candidate_builds(session, releases, target_version, opts):
    target_xy = Version(target_version).release[:2]
    tagged = kernel_builds_by_release(session, releases, opts.include_testing)

    candidates = []
    for release, builds in tagged.items():
        usable = [
            build
            for build in builds
            if (opts.include_rc or not is_rc(build))
            and Version(build["version"]).release[:2] <= target_xy
        ]
        if not usable:
            continue
        best = max(usable, key=build_sort_key)
        best["fedora_release"] = release
        candidates.append(best)

    # Closest kernel first, then the newest Fedora branch carrying it.
    candidates.sort(
        key=lambda b: (
            Version(b["version"]),
            b["fedora_release"],
            b["build_id"],
        ),
        reverse=True,
    )
    return candidates


def rpm_sources(session, build, keys, package="kernel-core"):
    rpms = session.listRPMs(buildID=build["build_id"], arches=["x86_64"])
    rpm = next((r for r in rpms if r["name"] == package), None)
    if rpm is None:
        return None
    pathinfo = koji.PathInfo(topdir=KOJI_TOPURL)
    build_dir = pathinfo.build(build)
    for sig in session.queryRPMSigs(rpm_id=rpm["id"]):
        sigkey = (sig["sigkey"] or "").lower()
        key_file = keys.get(sigkey)
        if key_file is None:
            continue
        return {
            "nvra": f"{rpm['nvr']}.{rpm['arch']}",
            "key_file": key_file,
            "signed": f"{build_dir}/{pathinfo.signed(rpm, sigkey)}",
            "unsigned": f"{build_dir}/{pathinfo.rpm(rpm)}",
            "sighdr": f"{build_dir}/{pathinfo.sighdr(rpm, sigkey)}",
        }
    return None


def url_exists(url):
    request = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT):
            return True
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return False
        raise


def download(url, dest):
    with urllib.request.urlopen(url, timeout=DOWNLOAD_TIMEOUT) as response:
        with open(dest, "wb") as fd:
            shutil.copyfileobj(response, fd)


def check_signature(rpm_file, key_file, tmpdir):
    rpmdb = tmpdir / f"rpmdb-{key_file.name}"
    shutil.rmtree(rpmdb, ignore_errors=True)
    rpmdb.mkdir(parents=True)
    subprocess.run(
        ["rpmkeys", "--dbpath", str(rpmdb), "--import", str(key_file)],
        check=True,
    )
    result = subprocess.run(
        ["rpmkeys", "--dbpath", str(rpmdb), "--checksig", str(rpm_file)],
        capture_output=True,
        text=True,
        check=True,
    )
    if "signatures OK" not in result.stdout:
        raise Exception(f"signature check failed: {result.stdout.strip()}")


def extract_config_from_rpm(rpm_file):
    cmd = (
        f"set -o pipefail; rpm2cpio {shlex.quote(str(rpm_file))}"
        " | cpio --quiet -i --to-stdout './lib/modules/*/config'"
    )
    result = subprocess.run(
        ["bash", "-c", cmd], capture_output=True, text=True, check=True
    )
    if "CONFIG_" not in result.stdout:
        raise Exception(f"no kernel config found in {rpm_file.name}")
    return result.stdout


def fetch_rpm(source, tmpdir):
    # Koji keeps a whole signed rpm only for some builds, mostly archived ones.
    # Everywhere else it serves the unsigned rpm and the detached signature
    # header, which splice back into the signed rpm the build system published.
    dest = tmpdir / f"{source['nvra']}.rpm.untrusted"
    if url_exists(source["signed"]):
        download(source["signed"], dest)
        return dest
    unsigned = tmpdir / f"{source['nvra']}.rpm.unsigned"
    sighdr = tmpdir / f"{source['nvra']}.sighdr"
    download(source["unsigned"], unsigned)
    download(source["sighdr"], sighdr)
    koji.splice_rpm_sighdr(sighdr.read_bytes(), str(unsigned), str(dest))
    unsigned.unlink()
    sighdr.unlink()
    return dest


def fetch_config(source, tmpdir):
    rpm_file = fetch_rpm(source, tmpdir)
    check_signature(rpm_file, source["key_file"], tmpdir)
    config = extract_config_from_rpm(rpm_file)
    rpm_file.unlink()
    return config


def extract_kernel_sources(archive_path, extract_dir):
    with tarfile.open(archive_path, "r") as tar:
        tar.extractall(path=str(extract_dir))


def run_make_oldconfig(kernel_source_dir):
    cmd = "yes '' | make oldconfig"
    subprocess.run(
        cmd,
        shell=True,
        cwd=str(kernel_source_dir),
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def remove_first_lines(file_path, n):
    lines = file_path.read_text().splitlines(keepends=True)
    file_path.write_text("".join(lines[n:]))


def prepend_header(config_file, header, output_file):
    config_contents = config_file.read_text()
    output_file.write_text(header + "\n" + config_contents)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Fetch from Koji the Fedora kernel config closest to the "
        "kernel version being packaged"
    )
    parser.add_argument("--include-rc", action="store_true")
    parser.add_argument("--include-testing", action="store_true")
    parser.add_argument("--kerneldir", type=Path, help="Kernel directory")
    parser.add_argument(
        "--keysdir", type=Path, required=True, help="GPG keys directory"
    )
    parser.add_argument(
        "--target-version",
        help="Kernel version to match, defaults to KERNELDIR/version",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Only report which Fedora build would be used",
    )
    args = parser.parse_args()
    if not args.kerneldir and not args.target_version:
        parser.error("either --kerneldir or --target-version is required")
    if not args.kerneldir and not args.dry_run:
        parser.error("--kerneldir is required unless --dry-run is given")
    return args


def main():
    args = parse_args()

    if args.target_version:
        kernelver = args.target_version
    else:
        version_file = args.kerneldir / "version"
        assert version_file.exists(), "version file not found"
        kernelver = version_file.read_text().strip()

    kernelsrc = f"linux-{kernelver}"
    if args.kerneldir and not args.dry_run:
        kernelarchive = args.kerneldir / f"{kernelsrc}.tar"
        assert (
            kernelarchive.exists()
        ), f"Kernel archive '{kernelarchive}' not found"

    keys, releases = load_signing_keys(args.keysdir)
    assert keys, f"No Fedora signing key found in '{args.keysdir}'"

    session = koji.ClientSession(KOJI_HUB)
    candidates = candidate_builds(session, releases, kernelver, args)

    print(f"Target kernel version: {kernelver}")
    if not candidates:
        print("No Fedora kernel config for this version, keeping current one")
        return

    # Every Fedora branch carrying the best kernel is an equivalent source, so
    # they cover for each other. Anything below is a different kernel and would
    # silently land a config nobody asked for, better to fail the update.
    best_version = candidates[0]["version"]
    eligible = [b for b in candidates if b["version"] == best_version]

    print("Fedora candidates, best first:")
    for build in candidates:
        mark = "*" if build["version"] == best_version else " "
        print(f" {mark} f{build['fedora_release']:<3} {build['nvr']}")

    tmp_base = Path.home() / "tmp"
    tmp_base.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="kernel-", dir=str(tmp_base)
    ) as tmpdirname:
        tmpdir = Path(tmpdirname)

        chosen = None
        for build in eligible:
            source = rpm_sources(session, build, keys)
            if source is None:
                print(
                    f"Skipping {build['nvr']}: no signed kernel-core",
                    file=sys.stderr,
                )
                continue
            if args.dry_run:
                print(f"Would use {source['nvra']}")
                if url_exists(source["signed"]):
                    print(f"  url: {source['signed']}")
                else:
                    print(f"  rpm: {source['unsigned']}")
                    print(f"  sig: {source['sighdr']}")
                print(f"  key: {source['key_file']}")
                return
            try:
                config_content = fetch_config(source, tmpdir)
                chosen, nvra = build, source["nvra"]
                break
            except Exception as e:
                print(f"Skipping {build['nvr']}: {e}", file=sys.stderr)

        if chosen is None:
            fallback = next(
                (b["nvr"] for b in candidates if b["version"] != best_version),
                "nothing",
            )
            raise Exception(
                f"no usable Fedora build for kernel {best_version}, "
                f"refusing to fall back to {fallback}"
            )

        print(f"Using {nvra}")

        try:
            extract_kernel_sources(kernelarchive, tmpdir)
        except Exception as e:
            raise Exception(f"Extracting kernel sources failed: {e}")

        kernel_source_dir = tmpdir / kernelsrc
        if not kernel_source_dir.exists():
            raise Exception(
                f"Extracted kernel source directory '{kernel_source_dir}' not found"
            )

        config_path = kernel_source_dir / ".config"
        config_path.write_text(config_content)

        try:
            run_make_oldconfig(kernel_source_dir)
        except Exception as e:
            raise Exception(f"Running make oldconfig failed: {e}")

        remove_first_lines(config_path, 4)

        header = (
            f"# Base config based on Fedora's config (kernel-core-{chosen['version']}-{chosen['release']}.rpm)\n"
            "# Only modification is `yes '' | make oldconfig` to drop config settings which\n"
            "# depend on Fedora patches and adjust for the small version difference."
        )
        output_config = args.kerneldir / "config-base"
        prepend_header(config_path, header, output_config)


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        print(f"Fatal error: {err}", file=sys.stderr)
        sys.exit(1)
