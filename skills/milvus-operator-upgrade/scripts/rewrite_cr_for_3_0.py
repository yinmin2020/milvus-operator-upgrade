#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Rewrite a Milvus CR yaml for Cluster→3.0 apply: set image, root securityContext,
explicit indexNode.replicas=0, strip status/managedFields/resourceVersion.
Does not require PyYAML.
Usage: rewrite_cr_for_3_0.py <cr.yaml> <image>
Prints COMP_KEYS=a,b,c on stdout.
"""
from __future__ import print_function
import re, sys

def main():
    path, img = sys.argv[1], sys.argv[2]
    text = open(path, encoding='utf-8').read()
    # strip status
    text = re.sub(r'(?ms)^status:\s*\n(?:  .*\n?)*', '', text)
    # strip noisy metadata fields (keep name/namespace/labels/annotations)
    for fld in ('resourceVersion', 'uid', 'generation', 'creationTimestamp',
                'managedFields', 'selfLink'):
        text = re.sub(r'(?ms)^  %s:.*?(?=^  [a-zA-Z]|^[a-zA-Z])' % fld, '', text)
    # set components.image (children of components are indented 4 spaces in typical kubectl yaml)
    if re.search(r'(?m)^    image:', text):
        text = re.sub(r'(?m)^(    image:).*$', r'\1 ' + img, text, count=1)
    elif re.search(r'(?m)^  image:', text):
        text = re.sub(r'(?m)^(  image:).*$', r'\1 ' + img, text, count=1)
    else:
        text = re.sub(r'(?m)^(  components:\s*)$', r'\1\n    image: ' + img, text, count=1)
    if not re.search(r'(?m)^    securityContext:', text) and not re.search(r'(?m)^  securityContext:', text):
        text = re.sub(r'(?m)^(    image:.*)$',
                      r'\1\n    securityContext:\n      runAsUser: 0\n      runAsNonRoot: false',
                      text, count=1)
    if re.search(r'(?m)^    indexNode:', text):
        if re.search(r'(?m)^    indexNode:\n(?:      .*\n)*?      replicas:', text):
            text = re.sub(r'(?m)^(    indexNode:\n(?:      .*\n)*?      replicas:)\s*\S*',
                          r'\1 0', text, count=1)
        else:
            text = re.sub(r'(?m)^(    indexNode:\s*)$', r'\1\n      replicas: 0', text, count=1)
    else:
        text = re.sub(r'(?m)^(  components:\s*)$', r'\1\n    indexNode:\n      replicas: 0', text, count=1)
    open(path, 'w', encoding='utf-8').write(text)
    keys = []
    in_comp = False
    for line in text.splitlines():
        if re.match(r'^  components:\s*$', line):
            in_comp = True
            continue
        if in_comp:
            m2 = re.match(r'^    ([A-Za-z0-9_]+):', line)
            if m2:
                keys.append(m2.group(1))
                continue
            if re.match(r'^  [a-zA-Z]', line):
                break
    print('COMP_KEYS=' + ','.join(keys))
    return 0

if __name__ == '__main__':
    sys.exit(main())
