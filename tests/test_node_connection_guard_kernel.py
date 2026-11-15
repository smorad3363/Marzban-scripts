#!/usr/bin/env python3
"""Real IPv4/IPv6 admission tests in two disposable network namespaces."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def run(args):
    return subprocess.run(args, text=True, capture_output=True, check=True, timeout=20).stdout


SERVER = r'''
import importlib.util,json,socket,threading,sys
spec=importlib.util.spec_from_file_location('guard',sys.argv[1]);g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
firewall=g.Firewall(['iptables','ip6tables'])
def echo(stream):
 with stream:
  while True:
   data=stream.recv(1024)
   if not data:return
   stream.sendall(data)
def accept(server):
 while True:
  stream,_=server.accept();threading.Thread(target=echo,args=(stream,),daemon=True).start()
servers=[]
for port in (30080,30081):
 s=socket.socket(socket.AF_INET6);s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,0);s.bind(('::',port));s.listen();servers.append(s)
 threading.Thread(target=accept,args=(s,),daemon=True).start()
udp=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM);udp.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,0);udp.bind(('::',30080))
def datagrams():
 while True:
  data,address=udp.recvfrom(1024);udp.sendto(data,address)
threading.Thread(target=datagrams,daemon=True).start()
print('ready',flush=True)
try:
 for line in sys.stdin:
  command=json.loads(line)
  firewall.apply({30080},command['paused']);print('applied',flush=True)
finally:firewall.clear()
'''

CLIENT = r'''
import socket,sys,json
addresses=['10.231.83.1','fd42:231:83::1']
streams=[socket.create_connection((a,30080),timeout=2) for a in addresses]
def echo(stream):
 stream.sendall(b'live-data');assert stream.recv(9)==b'live-data'
for stream in streams:echo(stream)
print('ready',flush=True)
for line in sys.stdin:
 paused=json.loads(line)['paused']
 for stream in streams:echo(stream)
 for address in addresses:
  try:
   with socket.create_connection((address,30080),timeout=2) as stream:
    echo(stream)
   assert not paused,'New connection bypassed active gate'
  except (ConnectionRefusedError,ConnectionResetError):
   assert paused,'Open gate refused a new connection'
  with socket.create_connection((address,30081),timeout=2) as stream:echo(stream)
  family=socket.AF_INET6 if ':' in address else socket.AF_INET
  with socket.socket(family,socket.SOCK_DGRAM) as udp:
   udp.settimeout(2);udp.sendto(b'udp-live',(address,30080));assert udp.recv(20)==b'udp-live'
 print('passed',flush=True)
'''


def exchange(process, value, expected):
    if value is not None:
        process.stdin.write(json.dumps(value)+'\n');process.stdin.flush()
    line=process.stdout.readline().strip()
    if line != expected:
        raise RuntimeError('Namespace fixture failed: '+line)


def main():
    if os.geteuid()!=0 or os.environ.get('GITHUB_ACTIONS')!='true':
        raise SystemExit('Run only on a disposable root GitHub Actions runner')
    suffix=str(os.getpid());server='mzn-s-'+suffix;client='mzn-c-'+suffix
    processes=[]
    try:
        for name in (server,client):run(['ip','netns','add',name])
        run(['ip','link','add','mzn-vs','type','veth','peer','name','mzn-vc'])
        for name,link,address,v6 in [(server,'mzn-vs','10.231.83.1/30','fd42:231:83::1/64'),(client,'mzn-vc','10.231.83.2/30','fd42:231:83::2/64')]:
            run(['ip','link','set',link,'netns',name]);run(['ip','-n',name,'link','set','lo','up'])
            run(['ip','-n',name,'address','add',address,'dev',link])
            run(['ip','-n',name,'-6','address','add',v6,'dev',link,'nodad'])
            run(['ip','-n',name,'link','set',link,'up'])
        server_process=subprocess.Popen(['ip','netns','exec',server,sys.executable,'-u','-c',SERVER,str(ROOT/'node-runtime/connection_guard.py')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
        processes.append(server_process);exchange(server_process,None,'ready')
        client_process=subprocess.Popen(['ip','netns','exec',client,sys.executable,'-u','-c',CLIENT],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
        processes.append(client_process);exchange(client_process,None,'ready')
        for paused in (True,False,True,False):
            exchange(server_process,{'paused':paused},'applied');exchange(client_process,{'paused':paused},'passed')
        print('PASS: real IPv4/IPv6 new sessions gated; established, control and UDP preserved; reopening succeeded',flush=True)
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.stdin.close()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()
        for name in (client,server):subprocess.run(['ip','netns','delete',name],capture_output=True)


if __name__=='__main__':main()
