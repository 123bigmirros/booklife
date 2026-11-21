#!/usr/bin/env python3
"""Exercise bitmap placement and clipping in the production CLI over a real PTY.
Checks protocol payloads and text cells; does not claim to screenshot Ghostty.
"""
import base64, fcntl, importlib.util, os, pathlib, pty, re, signal, struct, subprocess, tempfile, termios

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('layout', ROOT/'scripts/checks/terminal-layout-check.py')
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAABAAAAAICAYAAADwdn+XAAAAGUlEQVR4nGP4z8DwHx8mIP2foIpRA4aCAQCNpv8BMqhbfwAAAABJRU5ErkJggg==')

class GraphicsScreen(layout.Screen):
    def __init__(self, cols, rows):
        super().__init__(cols, rows)
        self.stream = b''
        self.placements = {}
        self.parts = b''
        self.header = None
        self.transmissions = 0
    def text_cells(self, data):
        pieces = data.split(b'\x1b[2K')
        for i,piece in enumerate(pieces):
            if i:
                self.placements = {ident:img for ident,img in self.placements.items()
                                   if not img['row'] <= self.row < img['row']+img['rows']}
                super().feed(b'\x1b[2K')
            super().feed(piece)
    def feed(self, data):
        self.stream += data
        while self.stream:
            match = re.search(rb'\x1b(?:_G|\]1337;)', self.stream)
            if match is None:
                # Retain an incomplete graphics introducer across read calls.
                keep = next((n for n in range(min(7,len(self.stream)),0,-1)
                             if b'\x1b_G'.startswith(self.stream[-n:]) or b'\x1b]1337;'.startswith(self.stream[-n:])),0)
                self.text_cells(self.stream[:-keep] if keep else self.stream)
                self.stream = self.stream[-keep:] if keep else b''
                return
            self.text_cells(self.stream[:match.start()])
            self.stream = self.stream[match.start():]
            kitty = self.stream.startswith(b'\x1b_G')
            end = self.stream.find(b'\x1b\\' if kitty else b'\x07')
            if end < 0: return
            packet = self.stream[3:end] if kitty else self.stream[7:end]
            self.stream = self.stream[end+(2 if kitty else 1):]
            if kitty:
                command,payload = packet.split(b';',1)
                params = dict(part.split(b'=',1) for part in command.split(b','))
                if params.get(b'a') == b'd':
                    self.placements.pop(int(params[b'i']),None)
                    continue
                if params.get(b'a') == b'T':
                    self.header = params
                    self.position = (self.row,self.col)
                    self.parts = b''
                assert params.get(b'q') == b'2', 'graphics replies must be disabled'
                self.parts += payload
                if params[b'm'] == b'1': continue
                params = self.header
                png = base64.b64decode(self.parts)
                ident, cols, rows = int(params[b'i']),int(params[b'c']),int(params[b'r'])
            else:
                command,payload = packet.split(b':',1)
                params = dict(part.split(b'=',1) for part in command.split(b';'))
                assert params[b'File'] == b'inline=1'
                png = base64.b64decode(payload)
                ident,cols,rows = self.row,int(params[b'width']),int(params[b'height'])
                self.position = (self.row,self.col)
            assert png.startswith(b'\x89PNG\r\n\x1a\n')
            width,height = struct.unpack('>II',png[16:24])
            row,col = self.position
            assert 3 <= row and row+rows <= self.rows-3, ('vertical image overflow',row,rows)
            assert col >= 0 and col+cols <= self.cols, 'horizontal image overflow'
            self.placements[ident] = dict(row=row,col=col,rows=rows,cols=cols,width=width,height=height)
            self.transmissions += 1

class Reader(layout.Reader):
    def __init__(self, book, state, program='ghostty', cols=80, rows=24, protocol=None):
        self.master,slave = pty.openpty()
        self.original = termios.tcgetattr(slave)
        fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))
        self.screen = GraphicsScreen(cols,rows)
        env = dict(os.environ,TERM='xterm-256color',TERM_PROGRAM=program,BOOKSLIDE_TERMINAL_STATE_DIR=str(state))
        env.pop('BOOKSLIDE_IMAGES',None)
        if protocol: env['BOOKSLIDE_IMAGES'] = protocol
        args = [os.environ.get('BOOKSLIDE_EXECUTABLE', str(pathlib.Path.home()/'Library/Caches/AppleProjectBuilds/book-slide/swift/debug/bookslide')),str(book),'--no-remote']
        self.proc = subprocess.Popen(args,stdin=slave,stdout=slave,stderr=slave,env=env)
        os.close(slave)
        self.read(initial=True)
        assert self.screen.active, 'reader did not enter alternate screen'
    def close(self):
        self.key(b'q')
        self.proc.wait(timeout=5)
        assert self.proc.returncode == 0 and not self.screen.active, 'terminal cleanup'
        assert termios.tcgetattr(self.master) == self.original, 'terminal input settings not restored'
        os.close(self.master)
    def resize(self,cols,rows):
        self.screen = GraphicsScreen(cols,rows)
        self.screen.active = True
        fcntl.ioctl(self.master,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))
        self.proc.send_signal(signal.SIGWINCH)
        self.read()

with tempfile.TemporaryDirectory(prefix='bookslide-images-') as tmp:
    tmp = pathlib.Path(tmp)
    book = tmp/'fixture.epub'
    (book/'META-INF').mkdir(parents=True)
    (book/'META-INF/container.xml').write_text('<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>')
    (book/'content.opf').write_text('<package><metadata><title>插图与小节排版验证</title></metadata><manifest><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>')
    (book/'picture.png').write_bytes(PNG)
    (book/'chapter.xhtml').write_text('<html><body><h5>小节标题</h5><p>One\n <em>continuous</em> paragraph.</p><img src="picture.png" alt="红蓝插图"/><h6>插图之后</h6>'+''.join(f'<p>后续正文第{i}段，检查图片不会遮挡文字。</p>' for i in range(35))+'</body></html>')
    for program in ('ghostty','iTerm.app','Apple_Terminal'):
        reader = Reader(book,tmp/program,program)
        try:
            text = reader.screen.text()
            assert 'One continuous paragraph.' in text
            assert any(cell[2] for row in reader.screen.grid for cell in row if cell[0] == '小'), 'heading not bold'
            if program == 'Apple_Terminal':
                assert not reader.screen.placements
                assert '[红蓝插图]' in text
                continue
            assert reader.screen.placements, 'inline bitmap missing'
            assert '[红蓝插图]' not in text
            full = next(iter(reader.screen.placements.values()))
            assert 0 < full['height'] <= 8
            reader.key(b'j'*8)
            cropped = next(iter(reader.screen.placements.values()))
            assert cropped['height'] < full['height'], ('partially scrolled image was not cropped',program,full,cropped)
            reader.key(b'?')
            if program == 'ghostty': assert not reader.screen.placements, 'image leaked into help'
            reader.key(b'?')
            assert reader.screen.placements
            for cols,rows in ((24,12),(140,40),(80,24)):
                reader.resize(cols,rows)
                assert not reader.screen.overflow
            reader.key(b'm')
            reader.key(b'g')
            reader.key(b'w')
            reader.key(b'j'*3)
            assert not reader.screen.overflow
        finally:
            reader.close()
    print('PASS: Ghostty/Kitty and iTerm2 bitmap payloads, viewport cropping, heading style, fallback, help, pagination, spacing, width, resize and exit')
