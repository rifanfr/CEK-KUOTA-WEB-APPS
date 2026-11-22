with open('cekkuota-kk/index.html', 'r', encoding='utf-8') as f:
    html = f.read()

import re
modal_ids = ['modal-qr-card', 'modal-qr-scanner', 'modal-add-customer', 'modal-edit-customer', 'modal-confirm', 'modal-privacy-detail', 'modal-edit-log', 'modal-export-center']

for i in range(len(modal_ids)-1):
    m1 = modal_ids[i]
    m2 = modal_ids[i+1]
    idx1 = html.find(f'id="{m1}"')
    idx2 = html.find(f'id="{m2}"')
    sub = html[idx1:idx2]
    opens = sub.count('<div')
    closes = sub.count('</div')
    print(f'{m1} -> {m2}: opens={opens}, closes={closes}, unclosed={opens - closes}')
