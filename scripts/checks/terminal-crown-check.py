#!/usr/bin/env python3
"""Exercise the production terminal reader's remote input in an isolated PTY."""
import os, pathlib, pty, select, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
CACHE = pathlib.Path.home()/'Library/Caches/AppleProjectBuilds/book-slide/terminal-crown'
PACKAGE = ROOT/'build/terminal-crown-probe'
(PACKAGE/'Sources/CrownProbe').mkdir(parents=True, exist_ok=True)
for name in ['BookSlideCore', 'BookSlideTerminal', 'BookSlideTransport']:
    link = PACKAGE/'Sources'/name
    if not link.exists(): link.symlink_to(ROOT/'Sources'/name, target_is_directory=True)
manifest = (ROOT/'Package.swift').read_text()
manifest += '''
package.products = [.executable(name:"CrownProbe",targets:["CrownProbe"])]
package.targets.removeAll { !["BookSlideCore","BookSlideTerminal","BookSlideTransport"].contains($0.name) }
package.targets.append(.executableTarget(name:"CrownProbe",dependencies:["BookSlideCore","BookSlideTerminal","BookSlideTransport"]))
'''
(PACKAGE/'Package.swift').write_text(manifest)
source = (ROOT/'Sources/BookSlideCLI/main.swift').read_text().split('\ndo {\n    setlocale',1)[0]
source += '''
setlocale(LC_ALL, "")
let reader = try TerminalReader(url:URL(fileURLWithPath:CommandLine.arguments[1]),remote:false,port:8766,mode:.scroll)
_ = tcgetattr(STDIN_FILENO,&reader.original)
reader.raw = true
reader.draw()
func wait(_ seconds: Double) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
func check(_ ok: Bool, _ message: String) {
    guard ok else { FileHandle.standardError.write(Data(("FAIL: "+message+"\\n").utf8)); exit(1) }
}
check(reader.snapshot?.supportsFractionalScroll == true,"advertise stream support")
let initial = reader.index
_ = reader.scrollRemotely(.next,lines:4)
check(reader.index == initial+4,"four-line packet follows received distance immediately")
wait(0.085)
check(reader.index == initial+4,"no timer-driven motion after the received distance")
let fractionalStart = reader.index
for _ in 0..<3 { _ = reader.scrollRemotely(.next,lines:0.25); wait(0.02) }
check(reader.index == fractionalStart,"fractions do not each jump a full row")
_ = reader.scrollRemotely(.next,lines:0.25); wait(0.07)
check(reader.index == fractionalStart+1,"fractional input accumulates to exactly one row")
_ = reader.scrollRemotely(.next,lines:4)
let reversingAt = reader.index
_ = reader.scrollRemotely(.previous,lines:1)
check(reader.index == reversingAt-1,"reverse brakes the pending forward batch immediately")
wait(0.22)
check(reader.index == reversingAt-1,"no stale forward tail after reverse")
_ = reader.scrollRemotely(.next,lines:4)
reader.consume(Array("c".utf8))
let stopped = reader.index
wait(0.22)
check(reader.index == stopped,"opening contents cancels queued movement")
FileHandle.standardError.write(Data("PASS: production terminal input: immediate distance, fractional gain, immediate reverse, cancelled tail\\n".utf8))
reader.finish()
'''
(PACKAGE/'Sources/CrownProbe/main.swift').write_text(source)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           CLANG_MODULE_CACHE_PATH=str(CACHE/'modules'))
subprocess.run(['xcrun','swift','build','--disable-sandbox','--package-path',str(PACKAGE),
                '--scratch-path',str(CACHE/'swift'),'--product','CrownProbe'],env=env,check=True)
with tempfile.TemporaryDirectory(prefix='bookslide-crown-') as directory:
    master, slave = pty.openpty()
    env.update(TERM='xterm-256color',BOOKSLIDE_TERMINAL_STATE_DIR=directory)
    process = subprocess.Popen([str(CACHE/'swift/debug/CrownProbe'),
        str(ROOT/'Sources/BookSlideMac/Resources/Reader/QuietHours.epub')],stdin=slave,stdout=slave,stderr=slave,env=env)
    os.close(slave)
    data=b''
    try:
        until=time.monotonic()+30
        while time.monotonic()<until:
            if select.select([master],[],[],0.1)[0]:
                try: data+=os.read(master,65536)
                except OSError: break
            if process.poll() is not None: break
        process.wait(timeout=2)
        text=data.decode(errors='replace')
        assert process.returncode == 0 and 'PASS:' in text, text[-1500:]
        print('PASS:'+text.split('PASS:',1)[1].splitlines()[0])
    finally:
        if process.poll() is None: process.kill(); process.wait()
        os.close(master)
