#!/usr/bin/env python3
"""Add the bundled public download page to an existing studio-hy2 installation."""
import base64,copy,fcntl,json,os,pathlib,shutil,signal,stat,subprocess,sys,tempfile,time

ASSETS=json.loads(base64.b64decode('eyJTSEEyNTZTVU1TIjogIjFiZWZjYzAxMTNlOTRlODk0MDg3ZGY4YmQxZTYyNGVkYmQ1Zjc1Zjc3Y2FhMWFkNGYxYzkzYzA1YjJhODEwODUgIGZpbGUtaW50ZWdyaXR5LWd1aWRlLnR4dFxuN2I5NzIwMTIyMjRkZWQyYmIwNGU0MTlkMTY2ZTAxZjdjOWQzMTU2YTYzMmE1N2QzYmYyY2Q1NDczNTE2ODhjNSAgcHJvamVjdC1ub3Rlcy10ZW1wbGF0ZS50eHRcbiIsICJmaWxlLWludGVncml0eS1ndWlkZS50eHQiOiAiRklMRSBJTlRFR1JJVFkgR1VJREVcblxuS2VlcCBhIGRvd25sb2FkZWQgZmlsZSBhbmQgaXRzIFNIQTI1NlNVTVMgZmlsZSBpbiB0aGUgc2FtZSBmb2xkZXIuXG5cbk9uIExpbnV4OlxuICBzaGEyNTZzdW0gLWMgU0hBMjU2U1VNU1xuXG5PbiBtYWNPUzpcbiAgc2hhc3VtIC1hIDI1NiAtYyBTSEEyNTZTVU1TXG5cbk9uIFdpbmRvd3MgUG93ZXJTaGVsbDpcbiAgR2V0LUZpbGVIYXNoIC5cXGZpbGUtaW50ZWdyaXR5LWd1aWRlLnR4dCAtQWxnb3JpdGhtIFNIQTI1NlxuXG5Db21wYXJlIHRoZSBjb21wbGV0ZSBoZXhhZGVjaW1hbCBkaWdlc3Qgd2l0aCB0aGUgdmFsdWUgaW4gU0hBMjU2U1VNUy5cbkEgbWF0Y2hpbmcgZGlnZXN0IGNvbmZpcm1zIHRoYXQgdGhlIGZpbGUgbWF0Y2hlcyB0aGF0IGNoZWNrc3VtLiBJdCBkb2VzXG5ub3QgZXN0YWJsaXNoIHdobyBjcmVhdGVkIHRoZSBmaWxlOyBvYnRhaW4gYm90aCBmcm9tIGEgc291cmNlIHlvdSB0cnVzdC5cblxuVGhpcyBndWlkZSBpcyBhbiBvcmlnaW5hbCB0ZXh0IGZpbGUgcHJvdmlkZWQgYnkgdGhpcyBkb3dubG9hZCBjZW50ZXIuXG5Zb3UgbWF5IGNvcHkgYW5kIGFkYXB0IGl0IGZvciB5b3VyIG93biB1c2UuXG4iLCAiaW5kZXguaHRtbCI6ICI8IWRvY3R5cGUgaHRtbD5cbjxodG1sIGxhbmc9XCJlblwiPlxuPGhlYWQ+XG48bWV0YSBjaGFyc2V0PVwidXRmLThcIj5cbjxtZXRhIG5hbWU9XCJ2aWV3cG9ydFwiIGNvbnRlbnQ9XCJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MVwiPlxuPG1ldGEgbmFtZT1cImRlc2NyaXB0aW9uXCIgY29udGVudD1cIkRvd25sb2FkIHVzZWZ1bCBwbGFpbi10ZXh0IGZpbGVzIGFuZCB2ZXJpZnkgdGhlaXIgU0hBLTI1NiBjaGVja3N1bXMuXCI+XG48dGl0bGU+RG93bmxvYWQgQ2VudGVyPC90aXRsZT5cbjxzdHlsZT5cbjpyb290e2NvbG9yLXNjaGVtZTpsaWdodDtmb250LWZhbWlseTotYXBwbGUtc3lzdGVtLEJsaW5rTWFjU3lzdGVtRm9udCxcIlNlZ29lIFVJXCIsc2Fucy1zZXJpZjtjb2xvcjojMjAyNTJiO2JhY2tncm91bmQ6I2Y3ZjdmNH0qe2JveC1zaXppbmc6Ym9yZGVyLWJveH1ib2R5e21hcmdpbjowfW1haW57bWF4LXdpZHRoOjk2MHB4O21hcmdpbjowIGF1dG87cGFkZGluZzo2NHB4IDI4cHggNDBweH0uZXllYnJvd3tmb250LXNpemU6MTNweDtsZXR0ZXItc3BhY2luZzouMWVtO3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtjb2xvcjojNjY3MTZjO21hcmdpbjowIDAgMTRweH1oMXtmb250LXNpemU6Y2xhbXAoMzRweCw1dncsNDhweCk7Zm9udC13ZWlnaHQ6NjAwO2xldHRlci1zcGFjaW5nOi0uMDM1ZW07bGluZS1oZWlnaHQ6MS4xO21hcmdpbjowIDAgMThweH0uaW50cm97Y29sb3I6IzU5NjE1ZDtsaW5lLWhlaWdodDoxLjc7bWF4LXdpZHRoOjYxMHB4O21hcmdpbjowIDAgNDBweH0uZmlsZXN7Ym9yZGVyLXRvcDoxcHggc29saWQgI2Q4ZGVkOX0uZmlsZXtkaXNwbGF5OmZsZXg7Z2FwOjIycHg7YWxpZ24taXRlbXM6ZmxleC1zdGFydDtwYWRkaW5nOjI4cHggMDtib3JkZXItYm90dG9tOjFweCBzb2xpZCAjZDhkZWQ5fS5maWxlLXR5cGV7cGFkZGluZzoxM3B4IDlweDtib3JkZXI6MXB4IHNvbGlkICNjZGQ3Y2Y7Ym9yZGVyLXJhZGl1czo1cHg7Y29sb3I6IzQwNTk0YTtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7YmFja2dyb3VuZDojZWRmMWVifS5maWxlLWluZm97ZmxleDoxO21pbi13aWR0aDowfWgye2ZvbnQtc2l6ZToxOXB4O2xpbmUtaGVpZ2h0OjEuNDttYXJnaW46MCAwIDdweDtmb250LXdlaWdodDo2MDB9LmZpbGUtaW5mbyBwe2ZvbnQtc2l6ZToxNXB4O2NvbG9yOiM2MjZhNjU7bGluZS1oZWlnaHQ6MS42O21hcmdpbjowIDAgMTBweH0ubWV0YXtjb2xvcjojNzQ3ZDc3O2ZvbnQtc2l6ZToxMnB4fS5tZXRhIHNwYW57cGFkZGluZzowIDdweH0uZG93bmxvYWR7ZGlzcGxheTppbmxpbmUtZmxleDtnYXA6MThweDthbGlnbi1pdGVtczpjZW50ZXI7cGFkZGluZzoxMHB4IDE1cHg7bWFyZ2luLXRvcDoycHg7Ym9yZGVyOjFweCBzb2xpZCAjYjZjNmI5O2JvcmRlci1yYWRpdXM6NXB4O2NvbG9yOiMyOTRkMzc7dGV4dC1kZWNvcmF0aW9uOm5vbmU7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NjAwO3doaXRlLXNwYWNlOm5vd3JhcH0uZG93bmxvYWQ6aG92ZXJ7YmFja2dyb3VuZDojZTllZmU4fWE6Zm9jdXMtdmlzaWJsZSxzdW1tYXJ5OmZvY3VzLXZpc2libGV7b3V0bGluZTozcHggc29saWQgIzY5N2ZjYTtvdXRsaW5lLW9mZnNldDo0cHh9ZGV0YWlsc3ttYXJnaW4tdG9wOjE0cHg7Zm9udC1zaXplOjEycHg7Y29sb3I6IzVlNjk2MH1zdW1tYXJ5e2N1cnNvcjpwb2ludGVyO3dpZHRoOmZpdC1jb250ZW50fWNvZGV7ZGlzcGxheTpibG9jazttYXJnaW4tdG9wOjEwcHg7b3ZlcmZsb3ctd3JhcDphbnl3aGVyZTtsaW5lLWhlaWdodDoxLjY7Y29sb3I6IzRmNWE1MX0udmVyaWZ5e21hcmdpbi10b3A6MzRweDttYXgtd2lkdGg6NzAwcHh9LnZlcmlmeSBoMntmb250LXNpemU6MTZweH0udmVyaWZ5IHB7Zm9udC1zaXplOjE0cHg7Y29sb3I6IzYyNmE2NTtsaW5lLWhlaWdodDoxLjd9LnZlcmlmeSBhe2NvbG9yOiMzMTU3M2Q7dGV4dC11bmRlcmxpbmUtb2Zmc2V0OjNweH1mb290ZXJ7bWFyZ2luLXRvcDo0NnB4O3BhZGRpbmctdG9wOjIwcHg7Ym9yZGVyLXRvcDoxcHggc29saWQgI2Q4ZGVkOTtjb2xvcjojN2E4MjdjO2ZvbnQtc2l6ZToxMnB4O2xpbmUtaGVpZ2h0OjEuNn0uc3Itb25seXtwb3NpdGlvbjphYnNvbHV0ZTt3aWR0aDoxcHg7aGVpZ2h0OjFweDtwYWRkaW5nOjA7bWFyZ2luOi0xcHg7b3ZlcmZsb3c6aGlkZGVuO2NsaXA6cmVjdCgwLDAsMCwwKTt3aGl0ZS1zcGFjZTpub3dyYXA7Ym9yZGVyOjB9QG1lZGlhKG1heC13aWR0aDo2MjBweCl7bWFpbntwYWRkaW5nOjQwcHggMjBweCAyOHB4fS5maWxle2dhcDoxNHB4O2ZsZXgtd3JhcDp3cmFwfS5maWxlLWluZm97ZmxleC1iYXNpczpjYWxjKDEwMCUgLSA2NHB4KX0uZG93bmxvYWR7bWFyZ2luLWxlZnQ6NThweH0uaW50cm97bWFyZ2luLWJvdHRvbToyOHB4fX1cbjwvc3R5bGU+XG48L2hlYWQ+XG48Ym9keT48bWFpbj5cbjxwIGNsYXNzPVwiZXllYnJvd1wiPkZpbGVzICZhbXA7IHJlc291cmNlczwvcD5cbjxoMT5Eb3dubG9hZCBDZW50ZXI8L2gxPlxuPHAgY2xhc3M9XCJpbnRyb1wiPlNtYWxsLCB1c2VmdWwgZmlsZXMgeW91IGNhbiBrZWVwIGFuZCBhZGFwdC4gRWFjaCBkb3dubG9hZCBpcyBhIHBsYWluLXRleHQgZmlsZSB3aXRoIGEgU0hBLTI1NiBjaGVja3N1bSBmb3IgY2hlY2tpbmcgaXRzIGNvbnRlbnRzLjwvcD5cbjxzZWN0aW9uIGNsYXNzPVwiZmlsZXNcIiBhcmlhLWxhYmVsPVwiQXZhaWxhYmxlIGRvd25sb2Fkc1wiPjxhcnRpY2xlIGNsYXNzPVwiZmlsZVwiPjxkaXYgY2xhc3M9XCJmaWxlLXR5cGVcIiBhcmlhLWhpZGRlbj1cInRydWVcIj5UWFQ8L2Rpdj48ZGl2IGNsYXNzPVwiZmlsZS1pbmZvXCI+PGgyPkZpbGUgaW50ZWdyaXR5IGd1aWRlPC9oMj48cD5BIHNob3J0IHJlZmVyZW5jZSBmb3IgY2hlY2tpbmcgU0hBLTI1NiBkaWdlc3RzIG9uIExpbnV4LCBtYWNPUywgYW5kIFdpbmRvd3MuPC9wPjxkaXYgY2xhc3M9XCJtZXRhXCI+UGxhaW4gdGV4dCA8c3BhbiBhcmlhLWhpZGRlbj1cInRydWVcIj5cdTAwYjc8L3NwYW4+IDU4MiBieXRlczwvZGl2PjxkZXRhaWxzPjxzdW1tYXJ5PlNIQS0yNTYgY2hlY2tzdW08L3N1bW1hcnk+PGNvZGU+MWJlZmNjMDExM2U5NGU4OTQwODdkZjhiZDFlNjI0ZWRiZDVmNzVmNzdjYWExYWQ0ZjFjOTNjMDViMmE4MTA4NTwvY29kZT48L2RldGFpbHM+PC9kaXY+PGEgY2xhc3M9XCJkb3dubG9hZFwiIGhyZWY9XCJmaWxlLWludGVncml0eS1ndWlkZS50eHRcIiBkb3dubG9hZD5Eb3dubG9hZCA8c3BhbiBjbGFzcz1cInNyLW9ubHlcIj5GaWxlIGludGVncml0eSBndWlkZTwvc3Bhbj48c3BhbiBhcmlhLWhpZGRlbj1cInRydWVcIj5cdTIxOTM8L3NwYW4+PC9hPjwvYXJ0aWNsZT5cbjxhcnRpY2xlIGNsYXNzPVwiZmlsZVwiPjxkaXYgY2xhc3M9XCJmaWxlLXR5cGVcIiBhcmlhLWhpZGRlbj1cInRydWVcIj5UWFQ8L2Rpdj48ZGl2IGNsYXNzPVwiZmlsZS1pbmZvXCI+PGgyPlByb2plY3Qgbm90ZXMgdGVtcGxhdGU8L2gyPjxwPkEgcGxhaW4tdGV4dCBzdGFydGluZyBwb2ludCBmb3IgZ29hbHMsIGFjdGlvbnMsIGRlY2lzaW9ucywgYW5kIHJlZmVyZW5jZSBmaWxlcy48L3A+PGRpdiBjbGFzcz1cIm1ldGFcIj5QbGFpbiB0ZXh0IDxzcGFuIGFyaWEtaGlkZGVuPVwidHJ1ZVwiPlx1MDBiNzwvc3Bhbj4gNDI2IGJ5dGVzPC9kaXY+PGRldGFpbHM+PHN1bW1hcnk+U0hBLTI1NiBjaGVja3N1bTwvc3VtbWFyeT48Y29kZT43Yjk3MjAxMjIyNGRlZDJiYjA0ZTQxOWQxNjZlMDFmN2M5ZDMxNTZhNjMyYTU3ZDNiZjJjZDU0NzM1MTY4OGM1PC9jb2RlPjwvZGV0YWlscz48L2Rpdj48YSBjbGFzcz1cImRvd25sb2FkXCIgaHJlZj1cInByb2plY3Qtbm90ZXMtdGVtcGxhdGUudHh0XCIgZG93bmxvYWQ+RG93bmxvYWQgPHNwYW4gY2xhc3M9XCJzci1vbmx5XCI+UHJvamVjdCBub3RlcyB0ZW1wbGF0ZTwvc3Bhbj48c3BhbiBhcmlhLWhpZGRlbj1cInRydWVcIj5cdTIxOTM8L3NwYW4+PC9hPjwvYXJ0aWNsZT48L3NlY3Rpb24+XG48c2VjdGlvbiBjbGFzcz1cInZlcmlmeVwiPjxoMj5WZXJpZnkgeW91ciBkb3dubG9hZDwvaDI+PHA+U2F2ZSB0aGUgPGEgaHJlZj1cIlNIQTI1NlNVTVNcIiBkb3dubG9hZD5jaGVja3N1bSBmaWxlPC9hPiBhbG9uZ3NpZGUgeW91ciBkb3dubG9hZHMsIHRoZW4gZm9sbG93IHRoZSBmaWxlIGludGVncml0eSBndWlkZS4gQSBtYXRjaGluZyBjaGVja3N1bSBjb25maXJtcyB0aGF0IHlvdXIgY29weSBtYXRjaGVzIHRoZSBmaWxlIGxpc3RlZCBoZXJlLjwvcD48L3NlY3Rpb24+XG48Zm9vdGVyPlRoZXNlIG9yaWdpbmFsIHRleHQgcmVzb3VyY2VzIGFyZSBwcm92aWRlZCBmb3IgY29weWluZyBhbmQgYWRhcHRhdGlvbi4gTm8gc2lnbi1pbiBpcyByZXF1aXJlZC48L2Zvb3Rlcj5cbjwvbWFpbj48L2JvZHk+PC9odG1sPlxuIiwgInByb2plY3Qtbm90ZXMtdGVtcGxhdGUudHh0IjogIlBST0pFQ1QgTk9URVNcblxuUHJvamVjdDpcbk93bmVyOlxuTGFzdCB1cGRhdGVkOlxuXG5QVVJQT1NFXG5XaGF0IHNob3VsZCB0aGlzIHByb2plY3QgbWFrZSBwb3NzaWJsZT9cblxuQ1VSUkVOVCBTVEFUVVNcbldoYXQgaXMgY29tcGxldGU/IFdoYXQgcmVtYWlucz9cblxuTkVYVCBBQ1RJT05TXG5BY3Rpb24gfCBPd25lciB8IER1ZSBkYXRlXG5cbkRFQ0lTSU9OU1xuRGF0ZSB8IERlY2lzaW9uIHwgUmVhc29uXG5cbk9QRU4gUVVFU1RJT05TXG5RdWVzdGlvbiB8IE5leHQgc3RlcFxuXG5SRUZFUkVOQ0UgRklMRVNcbkZpbGUgbmFtZSB8IERlc2NyaXB0aW9uIHwgTG9jYXRpb25cblxuVGhpcyBpcyBhbiBvcmlnaW5hbCBwbGFpbi10ZXh0IHRlbXBsYXRlIHByb3ZpZGVkIGJ5IHRoaXMgZG93bmxvYWQgY2VudGVyLlxuWW91IG1heSBjb3B5IGFuZCBhZGFwdCBpdCBmb3IgeW91ciBvd24gdXNlLlxuIn0='))
CONF=pathlib.Path('/etc/studio-hy2')
SITE=pathlib.Path('/var/lib/studio-hy2-downloads')
CORE=pathlib.Path('/opt/studio-hy2/sing-box')
SERVICE='studio-hy2.service'
LOCK=pathlib.Path('/run/lock/studio-hy2-install.lock')
LINEAGE=pathlib.Path('/etc/letsencrypt/live/studio-hy2')

def require(condition,message):
 if not condition:raise RuntimeError(message)

def regular_root_file(path):
 info=path.lstat()
 require(stat.S_ISREG(info.st_mode) and info.st_uid==0,'Expected root-owned regular file: '+str(path))

def write_atomic(path,data,mode):
 fd,name=tempfile.mkstemp(prefix='.studio-page-',dir=path.parent)
 try:
  with os.fdopen(fd,'wb') as stream:
   stream.write(data);stream.flush();os.fsync(stream.fileno());os.fchmod(stream.fileno(),mode);os.fchown(stream.fileno(),0,0)
  os.replace(name,path)
 finally:
  if os.path.exists(name):os.unlink(name)

def make_candidate(current,directory):
 candidate=copy.deepcopy(current)
 matches=[i for i in candidate.get('inbounds',[]) if i.get('type')=='hysteria2' and i.get('tag')=='hy2-in']
 require(len(matches)==1 and matches[0].get('listen_port')==443,'Expected one managed HY2 UDP443 inbound.')
 inbound=matches[0]
 require(inbound.get('tls',{}).get('enabled') is True and inbound.get('users'),'Existing authentication/TLS are required.')
 inbound['masquerade']={'type':'file','directory':str(directory)}
 return candidate

def public_tree(path):
 require(not path.is_symlink() and path.is_dir(),'Download root must be a real directory.')
 info=path.stat();require(info.st_uid==0 and not info.st_mode&0o022,'Download root must be root-owned and not writable by other users.')
 result={}
 for child in path.iterdir():
  require(child.name in ASSETS and not child.name.startswith('.'),'Unexpected entry in download root: '+child.name)
  regular_root_file(child)
  require(not child.stat().st_mode&0o022,'Public file is writable by other users: '+child.name)
  result[child.name]=child.read_bytes()
 return result

def ready():
 for _ in range(50):
  active=subprocess.run(['systemctl','is-active','--quiet',SERVICE]).returncode==0
  pid=subprocess.check_output(['systemctl','show','-p','MainPID','--value',SERVICE],text=True).strip()
  listeners=subprocess.check_output(['ss','-H','-lunp','sport = :443'],text=True)
  if active and pid.isdigit() and int(pid)>0 and 'pid='+pid+',' in listeners:return True
  time.sleep(.2)
 return False

def main():
 require(sys.platform.startswith('linux') and os.geteuid()==0,'Run with python3 as root on the VPS.')
 require(len(sys.argv)==1,'This patch takes no arguments; it uses the existing installation identity.')
 lock=open(LOCK,'w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 require(not CONF.is_symlink() and CONF.is_dir(),'Managed configuration directory is required.')
 for name in ('managed.json','server.json'):regular_root_file(CONF/name)
 require(json.loads((CONF/'managed.json').read_text()).get('format')==1,'Unrecognized installation marker.')
 require(subprocess.run(['systemctl','is-active','--quiet',SERVICE]).returncode==0,'Existing HY2 service must be active.')
 version=subprocess.check_output([str(CORE),'version'],text=True).splitlines()[0]
 require(version=='sing-box version 1.14.4','This patch was checked against sing-box 1.14.4 only.')
 marker=CONF/'download-page.managed.json'
 if marker.exists():
  regular_root_file(marker)
  require(json.loads(marker.read_text())=={'format':1,'directory':str(SITE)},'Unrecognized download-page marker.')
 previous_marker=marker.read_bytes() if marker.exists() else None
 previous_site=None
 if SITE.exists() or SITE.is_symlink():
  require(marker.exists(),'Existing download directory has no ownership marker; no files changed.')
  previous_site=public_tree(SITE)
 original=(CONF/'server.json').read_bytes();current=json.loads(original)
 candidate=make_candidate(current,SITE)
 rollback=CONF/'server.json.before-download-page'
 if rollback.exists() or rollback.is_symlink():regular_root_file(rollback)
 with tempfile.TemporaryDirectory(prefix='studio-page-check-',dir=CONF) as folder:
  stage=pathlib.Path(folder)/'public';stage.mkdir(mode=0o755)
  for name,content in ASSETS.items():(stage/name).write_text(content)
  check=make_candidate(current,stage)
  target=next(i for i in check['inbounds'] if i.get('tag')=='hy2-in' and i.get('type')=='hysteria2')
  expected='/run/credentials/'+SERVICE+'/'
  require(target['tls'].get('certificate_path')==expected+'cert.pem' and target['tls'].get('key_path')==expected+'key.pem','Unexpected credential paths; no files changed.')
  target['tls'].update(certificate_path=str(LINEAGE/'fullchain.pem'),key_path=str(LINEAGE/'privkey.pem'))
  check_path=pathlib.Path(folder)/'check.json';check_path.write_text(json.dumps(check));check_path.chmod(0o600)
  subprocess.run([str(CORE),'check','-c',str(check_path)],check=True)
 if not rollback.exists():write_atomic(rollback,original,0o600)
 changed_config=False;changed_site=False
 def interrupted(signum,frame):raise KeyboardInterrupt('Interrupted by signal '+str(signum))
 signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGHUP,interrupted)
 try:
  if previous_site is None:SITE.mkdir(mode=0o755)
  changed_site=True
  SITE.chmod(0o755);os.chown(SITE,0,0)
  for name,content in ASSETS.items():write_atomic(SITE/name,content.encode(),0o644)
  public_tree(SITE)
  changed_config=True;write_atomic(CONF/'server.json',json.dumps(candidate).encode()+b'\n',0o600)
  subprocess.run(['systemctl','restart',SERVICE],check=True)
  require(ready(),'HY2 did not become active and listen on UDP443 within 10 seconds.')
  write_atomic(marker,json.dumps({'format':1,'directory':str(SITE)}).encode()+b'\n',0o600)
 except BaseException:
  if changed_config:write_atomic(CONF/'server.json',original,0o600)
  if changed_site:
   if previous_site is None:shutil.rmtree(SITE)
   else:
    for child in SITE.iterdir():
     if child.name not in previous_site:child.unlink()
    for name,data in previous_site.items():write_atomic(SITE/name,data,0o644)
  if previous_marker is None:
   if marker.exists():marker.unlink()
  else:write_atomic(marker,previous_marker,0o600)
  if changed_config:
   restored=subprocess.run(['systemctl','restart',SERVICE],check=False)
   if restored.returncode:print('Original configuration restored, but HY2 restart failed; inspect the service journal.',file=sys.stderr)
  raise
 print('READY: HTTP/3 download page at '+str(SITE))
 print('Authentication, certificate paths, systemd units and renewal hooks were retained. No TCP service was added.')
 print('Original configuration backup: '+str(rollback))

if __name__=='__main__':
 try:main()
 except (Exception,KeyboardInterrupt) as exc:
  print('ERROR: '+str(exc),file=sys.stderr);sys.exit(1)
