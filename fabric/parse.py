import re,sys,glob
def parse(f):
    rows=[]
    for l in open(f):
        m=re.match(r'^\s+(\d+)\s+\d+\s+\w+\s+(?:\w+\s+)?-?\d+\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+(\d+|N/A)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+(\d+|N/A)',l)
        if m: rows.append((int(m[1]),float(m[2]),float(m[4]),float(m[6]),float(m[8]),sum(int(x) for x in (m[5],m[9]) if x!='N/A'))) if int(m[1])>0 else None
    return rows
for f in sorted(glob.glob('logs/nccl2.*.log')):
    r=parse(f)
    if not r: print(f,'NO DATA'); continue
    d={x[0]:x for x in r}
    peak=max(max(x[2],x[4]) for x in r); ps=[x[0] for x in r if max(x[2],x[4])==peak][0]
    big=r[-1]
    print(f.split('nccl2.')[1][:-4], 'maxsize',big[0],'minsize',r[0][0],'lat_min_oop',r[0][1],'lat_min_ip',r[0][3],'lat64K',d.get(65536,[0,0])[1],'peakbusbw',peak,'@',ps,'busbw@max',max(big[2],big[4]),'wrong',sum(x[5] for x in r))
