#!/usr/bin/env python3
"""Check real PTY screens and save their cell grids for visual review.
Only implements the cursor/erase/SGR subset emitted by BookSlide.
"""
import codecs, ctypes, fcntl, json, locale, os, pathlib, pty, re, select, signal, struct, subprocess, tempfile, termios, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/terminal-layout'
OUT.mkdir(parents=True, exist_ok=True)
locale.setlocale(locale.LC_ALL, '')
libc = ctypes.CDLL(None)
libc.wcwidth.argtypes = [ctypes.c_wchar]

class Screen:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.grid = [[[' ', False, False, False] for _ in range(cols)] for _ in range(rows)]
        self.row = self.col = 0
        self.scroll_top, self.scroll_bottom = 0, rows-1
        self.dim = self.bold = self.inverse = False
        self.active = False
        self.pending = ''
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self.overflow = False
    def feed(self, data):
        self.pending += self.decoder.decode(data)
        while self.pending:
            if self.pending == '\x1b': return
            if self.pending.startswith('\x1b['):
                m = re.match(r'\x1b\[([0-?]*)([ -/]*)([@-~])', self.pending)
                if not m: return
                self.pending = self.pending[m.end():]
                params, _, code = m.groups()
                if params == '?1049':
                    self.active = code == 'h'
                    continue
                if not self.active: continue
                nums = [int(v or '0') for v in params.split(';')] if not params.startswith('?') else []
                if code in 'Hf': self.row, self.col = (nums[0] or 1)-1, (nums[1] if len(nums)>1 and nums[1] else 1)-1
                elif code == 'G': self.col = (nums[0] or 1)-1
                elif code == 'J' and nums == [2]: self.grid = [[[' ', False, False, False] for _ in range(self.cols)] for _ in range(self.rows)]
                elif code == 'K' and nums == [2]: self.grid[self.row] = [[' ', False, False, False] for _ in range(self.cols)]
                elif code == 'r':
                    self.scroll_top = (nums[0] or 1)-1
                    self.scroll_bottom = (nums[1] if len(nums)>1 and nums[1] else self.rows)-1
                    self.row = self.col = 0
                elif code in ('S', 'T'):
                    count = min(nums[0] or 1, self.scroll_bottom-self.scroll_top+1)
                    region = self.grid[self.scroll_top:self.scroll_bottom+1]
                    blank = [[[' ', False, False, False] for _ in range(self.cols)] for _ in range(count)]
                    self.grid[self.scroll_top:self.scroll_bottom+1] = region[count:]+blank if code == 'S' else blank+region[:-count]
                elif code == 'm':
                    for n in nums:
                        if n == 0: self.dim = self.bold = self.inverse = False
                        elif n == 1: self.bold = True
                        elif n == 2: self.dim = True
                        elif n == 7: self.inverse = True
                continue
            char, self.pending = self.pending[0], self.pending[1:]
            if not self.active: continue
            if char == '\r': self.col = 0; continue
            if char == '\n': self.row += 1; continue
            width = max(0,libc.wcwidth(char))
            if not width: continue
            if not (0 <= self.row < self.rows and self.col + width <= self.cols): self.overflow = True
            else:
                self.grid[self.row][self.col] = [char,self.dim,self.bold,self.inverse]
                for offset in range(1,width): self.grid[self.row][self.col+offset] = ['',self.dim,self.bold,self.inverse]
            self.col += width
    def text(self): return '\n'.join(''.join(cell[0] for cell in row) for row in self.grid)
    def save(self, name):
        assert not self.overflow, name + ': terminal overflow'
        (OUT/(name+'.json')).write_text(json.dumps(dict(cols=self.cols,rows=self.rows,cells=self.grid),ensure_ascii=False))
        (OUT/(name+'.txt')).write_text(self.text())

class Reader:
    def __init__(self, directory, cols=80, rows=24, library=False):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH',rows,cols,0,0))
        self.screen = Screen(cols,rows)
        env = dict(os.environ, TERM='xterm-256color', BOOKSLIDE_TERMINAL_STATE_DIR=directory)
        args = [os.environ.get('BOOKSLIDE_EXECUTABLE',str(ROOT/'bookslide')), '--no-remote']
        if not library: args.append(str(ROOT/'Sources/BookSlideMac/Resources/Reader/QuietHours.epub'))
        self.proc = subprocess.Popen(args,stdin=slave,stdout=slave,stderr=slave,env=env)
        os.close(slave)
        self.read(initial=True)
    def read(self, initial=False):
        until = time.monotonic() + (20 if initial else 3)
        received = False
        while time.monotonic() < until:
            ready,_,_ = select.select([self.master],[],[],0.3)
            if not ready:
                if received and self.screen.active: break
                continue
            try: data = os.read(self.master,65536)
            except OSError: break
            self.screen.feed(data)
            received = True
    def key(self, key): os.write(self.master,key); self.read()
    def resize(self, cols, rows):
        self.screen = Screen(cols,rows); self.screen.active = True
        fcntl.ioctl(self.master,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))
        self.proc.send_signal(signal.SIGWINCH); self.read()
    def close(self):
        self.key(b'q'); self.proc.wait(timeout=5)
        assert self.proc.returncode == 0 and not self.screen.active, 'terminal cleanup'
        os.close(self.master)

if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='bookslide-layout-') as directory:
        r = Reader(directory)
        try:
            assert '%' in ''.join(c[0] for c in r.screen.grid[1])
            assert '行 · 滚动' not in r.screen.text() and 'm 模式' not in r.screen.text()
            assert '─' not in r.screen.text(), 'reading has no decorative divider'
            assert '? 帮助' in r.screen.text()
            assert '%' in ''.join(c[0] for c in r.screen.grid[1][-10:]), 'progress aligned right'
            for relaxed in [False, True]:
                if relaxed: r.key(b'g')
                for movement in [b'j', b'jjj', b'k', b'kkk']:
                    r.key(movement)
                    shifted = r.screen.text()
                    r.resize(80,24)
                    assert r.screen.text() == shifted, '\n'.join(['incremental scroll differs from repaint:'] + [f'{i+1}: {a!r} != {b!r}' for i,(a,b) in enumerate(zip(shifted.splitlines(),r.screen.text().splitlines())) if a != b])
            r.key(b'g')
            r.screen.save('01-reading-80')
            r.key(b'c'); r.screen.save('02-contents-80')
            assert any(cell[3] for row in r.screen.grid for cell in row), 'selected chapter highlight'
            r.key(b'?'); r.screen.save('03-help-80')
            assert '操作与外观' in r.screen.text()
            r.key(b'\x1b'); assert '目录' in r.screen.text(), 'help returns to contents'
            r.key(b'\x1b'); r.key(b'jjjjj')
            def location():
                for p in pathlib.Path(directory).glob('*.json'):
                    value = json.loads(p.read_text())
                    if isinstance(value,dict) and 'chapter' in value: return value
                raise AssertionError('Reading position was not saved')
            before = location()
            r.resize(140,32); r.key(b'w'); r.key(b'g')
            after = location()
            assert before['chapter'] == after['chapter'] and abs(before['offset']-after['offset']) <= 140, 'appearance keeps reading anchor'
            assert pathlib.Path(directory,'text-width').read_text() == 'wide'
            assert pathlib.Path(directory,'line-gap').read_text() == '1'
            r.screen.save('04-reading-wide-relaxed')
            r.resize(32,16); r.screen.save('05-reading-narrow')
            assert '%' in r.screen.text() and '? 帮助' in r.screen.text(), 'narrow progress/help'
            r.resize(24,10); r.screen.save('06-reading-minimum')
            r.resize(20,8); assert '请扩大终端窗口' in r.screen.text()
            r.resize(80,24); r.key(b'm'); assert pathlib.Path(directory,'view-mode').read_text() == 'paged'
            r.key(b'g'); r.key(b'g')
        finally: r.close()
        r = Reader(directory,140,32)
        try:
            r.key(b'?')
            assert '宽度：宽' in r.screen.text() and '行距：舒展' in r.screen.text(), 'appearance persists'
        finally: r.close()
        r = Reader(directory,library=True)
        try:
            assert '书库' in r.screen.text() and 'Enter 阅读' in r.screen.text()
            r.screen.save('07-library-80')
            r.key(b'\x1b[F'); r.screen.save('08-library-last')
            r.resize(32,16); r.screen.save('09-library-narrow')
        finally: r.close()
    print('PASS: real CLI screens at 24/32/80/140 columns, selection, help, mode switch, width/spacing persistence and cleanup')
