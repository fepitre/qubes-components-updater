#!/usr/bin/python3

import sys

from openqa_client.client import OpenQA_Client

client = OpenQA_Client(server='openqa.qubes-os.org')
params = {
    'DISTRI': 'qubesos',
    'VERSION': sys.argv[1],
    'FLAVOR': 'install-iso',
    'ARCH': 'x86_64',
    'BUILD': sys.argv[2],
    'ISO_URL': f'https://qubes.notset.fr/iso/{sys.argv[3]}',
}
print(client.openqa_request('POST', 'isos', params))
