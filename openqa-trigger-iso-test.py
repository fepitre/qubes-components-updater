#!/usr/bin/python3

import sys

from openqa_client.client import OpenQA_Client

client = OpenQA_Client(server='openqa.qubes-os.org')
params = {
    'ISO_URL': 'https://mirror.notset.fr/qubes/iso/{iso_name}'.format(
        iso_name=sys.argv[2]),
    'DISTRI': 'qubesos',
    'VERSION': '4.1',
    'FLAVOR': 'install-iso',
    'ARCH': 'x86_64',
    'BUILD': '{iso_date}-4.1'.format(iso_date=sys.argv[1])
}
print(client.openqa_request('POST', 'isos', params))
