import os, sys, torch, torch.distributed as dist
from instanttensor import safe_open
f = sorted(x for x in os.listdir('/m') if x.endswith('.safetensors'))[0]
dist.init_process_group('nccl', init_method='tcp://127.0.0.1:29555', rank=0, world_size=1, device_id=torch.device('cuda:0'))
pg = dist.GroupMember.WORLD if sys.argv[1] == 'pg' else None
try:
    with safe_open('/m/'+f, framework='pt', device=0, process_group=pg) as h:
        n = 0
        for k, t in h.tensors():
            n += 1
            if n > 3: break
    print('OK', f, n)
except Exception as e:
    print("FAIL", type(e).__name__, e)
print("MAPS", sorted({l.split()[-1] for l in open("/proc/self/maps") if "nccl" in l}))
