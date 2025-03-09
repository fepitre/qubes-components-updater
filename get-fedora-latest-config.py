#!/usr/bin/env python3
import argparse
import re
import subprocess
import sys
import tarfile
import tempfile
import koji
from pathlib import Path
from packaging.version import parse as parse_version


def get_koji_kernel_builds(include_rc, include_testing):
    session = koji.ClientSession("https://koji.fedoraproject.org/kojihub")
    build_targets = session.getBuildTargets()

    fedora_releases = set()
    release_to_targets = {}

    for target in build_targets:
        target_name = target["name"]
        m = re.match(r"f(\d+)$", target_name)
        if m:
            release_version = int(m.group(1))
            fedora_releases.add(release_version)
            release_to_targets.setdefault(release_version, set()).add(
                target_name
            )

    for release in fedora_releases:
        release_to_targets.setdefault(release, set()).add(f"f{release}-updates")
        if include_testing:
            release_to_targets.setdefault(release, set()).add(
                f"f{release}-updates-testing"
            )

    kernel_builds = []
    for release in sorted(fedora_releases, reverse=True):
        targets = release_to_targets[release]
        for target in targets:
            builds = session.listTagged(target, package="kernel")
            for build in builds:
                if not include_rc and "rc" in build["release"].lower():
                    continue
                kernel_builds.append(
                    {
                        "fedora_release": release,
                        "target": target,
                        "version": build["version"],
                        "release": build["release"],
                        "build_id": build["build_id"],
                    }
                )

    # Keep only the latest build per Fedora release.
    latest_builds = {}
    for build in kernel_builds:
        fedora_release = build["fedora_release"]
        if fedora_release not in latest_builds or parse_version(
            build["version"]
        ) > parse_version(latest_builds[fedora_release]["version"]):
            latest_builds[fedora_release] = build

    return list(latest_builds.values())


def is_close_version(target, candidate):
    t_parts = target.split(".")
    c_parts = candidate.split(".")
    return (
        len(t_parts) == 2
        and len(c_parts) == 2
        and t_parts[0] == c_parts[0]
        and 0 <= int(c_parts[1]) - int(t_parts[1]) <= 1
    )


def find_closest_build(builds, target_version_str):
    close_builds = [
        b for b in builds if is_close_version(target_version_str, b["version"])
    ]
    if close_builds:
        return max(close_builds, key=lambda b: parse_version(b["version"]))


def check_signature(rpm_file, key_file, tmpdir):
    rpmdb = tmpdir / "rpmdb"
    rpmdb.mkdir(exist_ok=True)
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
        raise Exception("Signature check failed")


def extract_config_from_rpm(rpm_file, kernel_build):
    # The expected path inside the RPM: ./lib/modules/<version>-<release>.x86_64/config
    config_path = f"./lib/modules/{kernel_build['version']}-{kernel_build['release']}.x86_64/config"
    cmd = f"rpm2cpio {rpm_file} | cpio --quiet -i --to-stdout {config_path}"
    result = subprocess.run(
        cmd, shell=True, capture_output=True, text=True, check=True
    )
    return result.stdout


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


def main():
    parser = argparse.ArgumentParser(
        description="Fetch Fedora kernel config using Koji builds and official Fedora repositories"
    )
    parser.add_argument("--include-rc", action="store_true")
    parser.add_argument("--include-testing", action="store_true")
    parser.add_argument(
        "--kerneldir", type=Path, required=True, help="Kernel directory"
    )
    parser.add_argument(
        "--keysdir", type=Path, required=True, help="GPG keys directory"
    )
    args = parser.parse_args()

    kerneldir = args.kerneldir
    version_file = kerneldir / "version"
    assert version_file.exists(), "version file not found"

    kernelver = version_file.read_text().strip()
    kernelsrc = f"linux-{kernelver}"
    kernelarchive = kerneldir / f"{kernelsrc}.tar"
    assert kernelarchive.exists(), f"Kernel archive '{kernelarchive}' not found"

    builds = get_koji_kernel_builds(
        include_rc=args.include_rc, include_testing=args.include_testing
    )
    assert builds, "No kernel builds found from Koji"

    chosen_build = find_closest_build(builds, kernelver)
    if not chosen_build:
        print("No new kernel config found.")
        return

    key_file = (
        args.keysdir
        / f"RPM-GPG-KEY-fedora-{chosen_build['fedora_release']}-primary"
    )
    assert key_file.exists(), f"Key file '{key_file}' not found"

    pkg_spec = (
        f"kernel-core-{chosen_build['version']}-{chosen_build['release']}"
    )
    expected_rpm = f"{pkg_spec}.x86_64.rpm"
    releasever = chosen_build["fedora_release"]

    repo_opts = f"--disablerepo=* --enablerepo=fedora --enablerepo=updates --releasever={releasever}"
    if args.include_testing:
        repo_opts += " --enablerepo=updates-testing"

    tmp_base = Path.home() / "tmp"
    tmp_base.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="kernel-", dir=str(tmp_base)
    ) as tmpdirname:
        tmpdir = Path(tmpdirname)
        cmd = f"dnf -q download {pkg_spec} {repo_opts}"
        subprocess.run(cmd, shell=True, check=True, cwd=str(tmpdir))
        rpm_file = tmpdir / expected_rpm
        assert (
            rpm_file.exists()
        ), f"Downloaded RPM '{expected_rpm}' not found in temporary directory"

        rpm_untrusted = rpm_file.with_name(rpm_file.name + ".untrusted")
        rpm_file.rename(rpm_untrusted)
        rpm_file = rpm_untrusted

        try:
            check_signature(rpm_file, key_file, tmpdir)
        except Exception as e:
            raise Exception(f"Signature check failed: {e}")

        try:
            config_content = extract_config_from_rpm(rpm_file, chosen_build)
        except Exception as e:
            raise Exception(f"Extracting config from RPM failed: {e}")

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
            f"# Base config based on Fedora's config (kernel-core-{chosen_build['version']}-{chosen_build['release']}.rpm)\n"
            "# Only modification is `yes '' | make oldconfig` to drop config settings which\n"
            "# depend on Fedora patches and adjust for the small version difference."
        )
        output_config = kerneldir / "config-base"
        prepend_header(config_path, header, output_config)


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        print(f"Fatal error: {err}", file=sys.stderr)
        sys.exit(1)
