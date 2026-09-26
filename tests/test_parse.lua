local H = require('tests.helpers')
local T = MiniTest.new_set()
local parse = require('perforated.core.parse')

-- Real output captured from p4/p4d 2025.2.
local FSTAT = table.concat({
  '{"clientFile":"/ws/a.txt","depotFile":"//depot/a.txt","haveRev":"1","headAction":"add","headChange":"1","headRev":"1","headType":"text","isMapped":""}',
  '{"data":"nothere.txt - no such file(s).\\n","generic":17,"severity":2}',
  '',
}, '\n')

T['jsonl'] = MiniTest.new_set()

T['jsonl']['splits records and warnings'] = function()
  local p = parse.jsonl(FSTAT)
  H.eq(#p.records, 1)
  H.eq(p.records[1].depotFile, '//depot/a.txt')
  H.eq(p.warnings, { 'nothere.txt - no such file(s).' })
  H.eq(p.errors, {})
  H.eq(p.bad, 0)
end

T['jsonl']['severity >= 3 is an error'] = function()
  local p = parse.jsonl(
    '{"data":"Perforce password (P4PASSWD) invalid or unset.\\n","generic":36,"severity":3}\n'
  )
  H.eq(p.errors, { 'Perforce password (P4PASSWD) invalid or unset.' })
  H.eq(#p.records, 0)
end

T['jsonl']['{ data, level } records (p4 status) are messages'] = function()
  local p = parse.jsonl(table.concat({
    '{"action":"delete","clientFile":"/w/c.txt","depotFile":"//depot/c.txt","localFile":"c.txt"}',
    '{"data":"//depot/c.txt - also opened by alice@ws2","level":1}',
    '',
  }, '\n'))
  H.eq(#p.records, 1)
  H.eq(p.warnings, { '//depot/c.txt - also opened by alice@ws2' })
end

T['jsonl']['{ data, level } messages are never errors, whatever the level'] = function()
  local p = parse.jsonl(table.concat({
    '{"data":"Diff chunks: 0 yours + 0 theirs + 0 both + 1 conflicting","level":34}',
    '{"data":"//alice_ws/a.txt - resolve skipped.","level":0}',
    '{"data":"No files to submit.\\n","generic":17,"severity":3}',
    '',
  }, '\n'))
  H.eq(#p.warnings, 2)
  H.eq(p.errors, { 'No files to submit.' })
end

T['jsonl']['tolerates blank lines and garbage'] = function()
  local p = parse.jsonl('\n{"User":"alice"}\nnot json\n')
  H.eq(p.records, { { User = 'alice' } })
  H.eq(p.bad, 1)
end

T['jsonl']['print output keeps data chunks as records'] = function()
  local out =
    '{"action":"add","depotFile":"//depot/a.txt","rev":"1"}\n{"data":"hi\\n"}\n{"data":""}\n'
  local p = parse.jsonl(out)
  H.eq(#p.records, 3)
  H.eq(p.records[2].data, 'hi\n')
end

T['line_splitter'] = function()
  local lines = {}
  local feed = parse.line_splitter(function(l)
    lines[#lines + 1] = l
  end)
  feed('ab')
  feed('c\nde')
  feed('f\n\ng')
  feed(nil)
  H.eq(lines, { 'abc', 'def', '', 'g' })
end

T['ztag text fallback'] = function()
  local text = table.concat({
    '... change 12',
    '... desc Fix crash',
    'second line',
    '',
    '... change 13',
    '... desc x',
    '',
  }, '\n')
  local p = parse.ztag(text)
  H.eq(
    p.records,
    { { change = '12', desc = 'Fix crash\nsecond line' }, { change = '13', desc = 'x' } }
  )
end

T['indexed'] = MiniTest.new_set()

T['indexed']['unfolds rev0/change0'] = function()
  local rec = {
    depotFile = '//d/f',
    rev0 = '3',
    change0 = '12',
    rev1 = '2',
    change1 = '9',
    desc0 = 'a',
    desc1 = 'b',
  }
  H.eq(
    parse.indexed(rec, { 'rev', 'change' }),
    { { rev = '3', change = '12' }, { rev = '2', change = '9' } }
  )
end

T['indexed']['two-level fields'] = function()
  local rec = {
    rev0 = '2',
    ['how0,0'] = 'copy from',
    ['file0,0'] = '//a',
    ['how0,1'] = 'merge from',
    ['file0,1'] = '//b',
  }
  local items = parse.indexed(rec)
  H.eq(items[1].rev, '2')
  H.eq(items[1].sub, { { how = 'copy from', file = '//a' }, { how = 'merge from', file = '//b' } })
end

T['indexed']['respects name filter'] = function()
  H.eq(parse.indexed({ rev0 = '1', other0 = 'x' }, { 'rev' }), { { rev = '1' } })
end

T['p4set'] = function()
  local text = table.concat({
    "P4CLIENT=cfgclient (config '/tmp/x/.p4config')",
    "P4CONFIG=.p4config (config '/tmp/x/.p4config' )",
    'P4DIFF=nvim -d',
    'P4EDITOR=vim (set)',
    "P4PORT=rsh:/bin/p4d -r /tmp/root -i (config '/tmp/x/.p4config')",
  }, '\n')
  local s = parse.p4set(text)
  H.eq(s.P4CLIENT, { value = 'cfgclient', source = 'config', path = '/tmp/x/.p4config' })
  H.eq(s.P4CONFIG.path, '/tmp/x/.p4config')
  H.eq(s.P4DIFF, { value = 'nvim -d', source = 'environment' })
  H.eq(s.P4EDITOR.source, 'set')
  H.eq(s.P4PORT.value, 'rsh:/bin/p4d -r /tmp/root -i')
end

T['annotate records'] = function()
  local history = require('perforated.history')
  local head, n, cls, meta = history._annotate_lines({
    { depotFile = '//depot/a.c', rev = '3' },
    { data = 'one\n', lower = '1', upper = '3', user = 'alice', time = '2026/01/01 10:00:00' },
    { data = 'a very long line, part one ', lower = '2', upper = '3', user = 'bob' },
    { data = 'and part two\n', lower = '2', upper = '3', user = 'bob' },
    { data = 'windows\r\n', lower = '3', upper = '3', user = 'alice' },
    { data = 'no final newline', lower = '3', upper = '3', user = 'alice' },
  })
  H.eq(head.depotFile, '//depot/a.c')
  H.eq(n, 4)
  H.eq(cls, { 1, 2, 3, 3 })
  H.eq(meta[2].user, 'bob')
  H.eq(meta[1].time, '2026/01/01 10:00:00')
end

return T
