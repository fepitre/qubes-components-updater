#!/usr/bin/python3

import sys
import argparse
import requests
import json

from github import Github
from packaging import version


class KernelUpdaterClient(Github):
    def __init__(self, account, branch, token=None):
        super().__init__(login_or_token=token)
        self.user = self.get_user(account)
        self.repo = self.user.get_repo('qubes-linux-kernel')
        self.branch = branch
        self.token = token

    def get_version_qubes(self):
        content = self.repo.get_contents('version', ref=self.branch)
        return content.decoded_content.decode('utf8').replace('\n', '')

    def get_version_upstream(self):
        url_releases = 'https://www.kernel.org/releases.json'
        r = requests.get(url_releases)
        latest_upstream = None

        if 200 <= r.status_code < 300:
            content = json.loads(r.content.decode('utf-8'))
            if self.branch == 'master':
                releases = [rel['version'] for rel in content['releases'] if rel['moniker'] == 'stable']
            elif 'stable-' in self.branch:
                branch_version = self.branch.split('-')[1]
                releases = [rel['version'] for rel in content['releases'] if
                            rel['moniker'] == 'longterm' and rel['version'].startswith(branch_version)]
            else:
                print('Unknown tag/branch: %s' % self.branch)

            if releases:
                latest_upstream = releases[0]
        else:
            print('An error occurred while downloading "%s"' % url_releases)

        return latest_upstream

    def is_autopr_present(self, version):
        present = False
        for pr in list(self.repo.get_pulls()):
            if 'UPDATE: ' + version in pr.title:
                present = True
                break
        return present

    def is_update_needed(self):
        version_qubes = self.get_version_qubes()
        version_upstream = self.get_version_upstream()
        if (not self.is_autopr_present(version_upstream)) and (
                version.parse(version_qubes) < version.parse(version_upstream)):
            return version_upstream

    def create_pullrequest(self, base, head):
        # example of head: 'fepitre:v4.19.30'
        parsed_head = head.split(':')
        if len(parsed_head) == 2:
            version = parsed_head[1].lstrip('update-v')
        else:
            print('An error occurred while parsing "repo:branch" from %s' % head)
            sys.exit(1)

        self.repo.create_pull(title="UPDATE: " + version,
                              body="Update to kernel-" + version,
                              base=base,
                              head=head,
                              maintainer_can_modify=True)


def parse_args(argv):
    parser = argparse.ArgumentParser()

    parser.add_argument('--check-update', required=False, action='store_true')
    parser.add_argument('--create-pullrequest', required=False, action='store_true')
    parser.add_argument('--token', required=False)
    parser.add_argument('--base', required=True)
    parser.add_argument('--head', required=False)

    args = parser.parse_args(argv[1:])

    return args


def main(argv):
    args = parse_args(argv)
    token = None

    # Token is only needed for PR
    if args.token:
        try:
            with open(args.token, 'r') as f:
                token = f.read().replace('\n', '')
        except IOError:
            print("An error occurred while reading token file '%s'" % args.token)

    # example of args.base: 'fepitre:stable-4.19'
    parsed_base = args.base.split(':')
    if len(parsed_base) == 2:
        account = parsed_base[0]
        branch = parsed_base[1]
    else:
        print('An error occurred while parsing "repo:branch" from %s' % args.base)
        sys.exit(1)

    client = KernelUpdaterClient(account=account, branch=branch, token=token)

    if args.check_update:
        is_update_needed = client.is_update_needed()
        if is_update_needed is not None:
            print(is_update_needed)

    if args.create_pullrequest and args.base and args.head:
        client.create_pullrequest(branch, args.head)

    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
