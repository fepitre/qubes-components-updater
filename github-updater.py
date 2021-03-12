#!/usr/bin/python3

import os
import sys
import argparse
import requests
import json
import subprocess

from github import Github
from packaging import version
from packaging.version import parse as parse_version


class UpdaterClient(Github):
    def __init__(self, account, repo, branch, token=None):
        super().__init__(login_or_token=token)
        self.user = self.get_user(account)
        self.repo = self.user.get_repo(repo)
        self.branch = branch
        self.token = token

    def get_version_qubes(self):
        qubes_version = None
        if self.repo.name == "qubes-gui-agent-linux":
            fnames = [f.name.replace('pulsecore-', '')
                      for f in self.repo.get_contents('pulse', ref=self.branch)
                      if f.name.startswith('pulsecore-')]
            fnames = sorted(fnames, key=parse_version, reverse=True)
            if fnames:
                qubes_version = fnames[0]
        else:
            content = self.repo.get_contents('version', ref=self.branch)
            qubes_version = content.decoded_content.decode('utf8').strip('\n')
        return qubes_version

    def get_version_upstream(self):
        latest_upstream = None
        if self.repo.name == "qubes-linux-kernel":
            url_releases = 'https://www.kernel.org/releases.json'
            r = requests.get(url_releases)
            latest_upstream = None
            if 200 <= r.status_code < 300:
                content = json.loads(r.content.decode('utf-8'))
                releases = [rel['version'] for rel in content['releases'] if
                            rel['moniker'] in ('stable', 'longterm')]

                releases.sort(key=parse_version, reverse=True)

                if 'stable-' in self.branch:
                    branch_version = self.branch.split('-')[1]
                    releases = [rel for rel in releases if
                                rel.startswith(branch_version)]

                latest_upstream = releases[0]
            else:
                print('An error occurred while downloading "%s"' % url_releases)

        return latest_upstream

    def is_autopr_present(self, version=None):
        present = False
        if not version:
            version = self.get_version_upstream()
        for pr in list(self.repo.get_pulls()):
            if f'UPDATE: {version}' in pr.title:
                present = True
                break
        return present

    def is_update_needed(self):
        version_qubes = self.get_version_qubes()
        version_upstream = self.get_version_upstream()
        if version_qubes and version_upstream:
            if (not self.is_autopr_present()) \
                    and (version.parse(version_qubes) <
                         version.parse(version_upstream)):
                return version_upstream

    def create_pullrequest(self, base, head, version=None):
        if not self.is_autopr_present(version):
            # example of head: 'fepitre:v4.19.30'
            parsed_head = head.split(':')
            if len(parsed_head) == 2:
                parsed_version = parsed_head[1].lstrip('update-v')
            else:
                raise ValueError(
                    f'An error occurred while parsing "repo:branch" from {head}')

            pr = self.repo.create_pull(title=f"UPDATE: {parsed_version}",
                                  body=f"Update to {parsed_version}",
                                  base=base,
                                  head=head,
                                  maintainer_can_modify=True)
            if not pr:
                raise ValueError(f'An error occurred while creating PR for {head}')
        else:
            print(f'Pull request already exists!')


def parse_args(argv):
    parser = argparse.ArgumentParser()

    parser.add_argument('--repo')
    parser.add_argument('--check-update',
                        required=False, action='store_true')
    parser.add_argument('--create-pullrequest',
                        required=False, action='store_true')
    parser.add_argument('--base', required=True)
    parser.add_argument('--head', required=False)
    parser.add_argument('--version', required=False)

    args = parser.parse_args(argv[1:])

    return args


def main(argv):
    args = parse_args(argv)
    token = os.environ.get('GITHUB_API_TOKEN', None)

    # example of args.base: 'fepitre:stable-4.19'
    parsed_base = args.base.split(':')
    if len(parsed_base) == 2:
        account = parsed_base[0]
        branch = parsed_base[1]
    else:
        print(f'An error occurred while parsing "repo:branch" from {args.base}')
        return 1

    client = UpdaterClient(
        account=account, repo=args.repo, branch=branch, token=token)

    if args.check_update:
        is_update_needed = client.is_update_needed()
        if is_update_needed is not None:
            print(is_update_needed)

    if args.create_pullrequest and args.base and args.head:
        try:
            client.create_pullrequest(branch, args.head, args.version)
        except ValueError as e:
            print(str(e))
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
