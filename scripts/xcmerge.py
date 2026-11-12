import json,subprocess,sys
f=sys.argv[1]
def load(stage):
    return json.loads(subprocess.check_output(['git','show',f':{stage}:{f}']))
base,ours,theirs=load(1),load(2),load(3)
out=ours
bs=base['strings']
for k,v in theirs['strings'].items():
    if k not in out['strings']:
        if k in bs and k not in ours['strings']: continue  # deleted in ours
        out['strings'][k]=v
    else:
        o=out['strings'][k]
        if o==bs.get(k): out['strings'][k]=v
        else:
            lo=o.setdefault('localizations',{})
            for l,lv in v.get('localizations',{}).items(): lo.setdefault(l,lv)
for k in list(out['strings']):
    if k in bs and k not in theirs['strings'] and out['strings'][k]==bs[k]: del out['strings'][k]
open(f,'w').write(json.dumps(out,ensure_ascii=False,indent=2,separators=(',',' : '),sort_keys=True)+'\n')
