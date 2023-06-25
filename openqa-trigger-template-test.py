#!/usr/bin/python3

import sys

from openqa_client.client import OpenQA_Client

release = sys.argv[1]
template = sys.argv[2]
template_name = "-".join(template.split("-")[:-2])


client = OpenQA_Client(server='openqa.qubes-os.org')
params = {
    'DISTRI': 'qubesos',
    'FLAVOR': 'templates',
    'ARCH': 'x86_64',
    'VERSION': release,  # Qubes release
    'BUILD': template,  # jammy-4.2.0-202305062059
    'UPDATE_TEMPLATES': f'https://qubes.notset.fr/repo/notset/yum/r{release}/templates-community-testing/rpm/qubes-template-{template}.noarch.rpm',
    'TEST_TEMPLATES': template_name
}
print(client.openqa_request('POST', 'isos', params))
