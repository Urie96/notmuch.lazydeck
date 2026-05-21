local M = {}

local cfg = {
  default_query = 'tag:inbox and not tag:deleted',
  queries = {
    inbox = 'tag:inbox and not tag:deleted',
    unread = 'tag:unread and not tag:deleted',
    starred = 'tag:flagged and not tag:deleted',
    sent = 'tag:sent',
    archive = 'not tag:inbox and not tag:deleted',
    trash = 'tag:deleted',
    all = '*',
  },
  labels = {
    inbox = 'Inbox',
    unread = 'Unread',
    starred = 'Starred',
    sent = 'Sent',
    archive = 'Archive',
    trash = 'Trash',
    all = 'All Mail',
  },
  order = { 'inbox', 'unread', 'starred', 'sent', 'archive', 'trash', 'all' },
  accounts = nil,
  account_order = nil,
  sync_command = { 'mbsync', '-a' },
  notmuch_new_command = { 'notmuch', 'new' },
  from = os.getenv('EMAIL_FROM') or '',
  sent_folder = 'Sent',
  keymap = {
    sync = 'S',
    compose = 'c',
    search = 'g/',
    archive = 'a',
    trash = 'd',
    unread = 'u',
    read = 'U',
    star = 's',
    unstar = 'x',
    reply = 'r',
  },
}

local state = {
  deps = nil,
  preview_cache = {},
  preview_pending = {},
  count_pending = {},
}

local thread_keymap = {}
local build_entries_for_current_root

local function tbl_contains(t, value)
  for _, v in ipairs(t or {}) do
    if v == value then return true end
  end
  return false
end

local function exec(cmd, cb)
  deck.system(cmd, function(out)
    cb(out or { code = 1, stdout = '', stderr = 'no command output' })
  end)
end

local function exec_stdin(cmd, stdin, cb)
  deck.system.exec(cmd, { stdin = stdin or '' }, function(out)
    cb(out or { code = 1, stdout = '', stderr = 'no command output' })
  end)
end

local function parse_json(stdout)
  local ok, data = pcall(deck.json.decode, stdout or '')
  if not ok then return nil, data end
  return data, nil
end

local function notify_error(prefix, out)
  local msg = prefix
  if out and out.stderr and out.stderr ~= '' then
    msg = msg .. ': ' .. out.stderr
  elseif out and out.stdout and out.stdout ~= '' then
    msg = msg .. ': ' .. out.stdout
  end
  deck.notify(msg)
end

local function has_accounts()
  return type(cfg.accounts) == 'table' and next(cfg.accounts) ~= nil
end

local function ordered_accounts()
  local result = {}
  if type(cfg.account_order) == 'table' then
    for _, name in ipairs(cfg.account_order) do
      if cfg.accounts[name] then table.insert(result, name) end
    end
    return result
  end
  for name, _ in pairs(cfg.accounts or {}) do table.insert(result, name) end
  table.sort(result)
  return result
end

local function account_query(name, acc)
  acc = acc or (cfg.accounts and cfg.accounts[name]) or {}
  if acc.query then return acc.query end
  if acc.tag then return 'tag:' .. acc.tag end
  return 'tag:account-' .. name
end

local function scoped_query(scope, key)
  if not scope or not scope.account then return cfg.queries[key] end

  local acc = cfg.accounts[scope.account] or {}
  local explicit = acc[key .. '_query']
  if explicit then return explicit end

  local base = account_query(scope.account, acc)
  if key == 'inbox' then return '(' .. base .. ') and tag:inbox and not tag:deleted' end
  if key == 'unread' then return '(' .. base .. ') and tag:unread and not tag:deleted' end
  if key == 'starred' then return '(' .. base .. ') and tag:flagged and not tag:deleted' end
  if key == 'sent' then return '(' .. base .. ') and tag:sent' end
  if key == 'archive' then return '(' .. base .. ') and not tag:inbox and not tag:deleted' end
  if key == 'trash' then return '(' .. base .. ') and tag:deleted' end
  if key == 'all' then return base end
  return base
end

local function scope_from_path(path)
  if has_accounts() and #path >= 2 and cfg.accounts[path[2]] then
    return { account = path[2], acc = cfg.accounts[path[2]] }
  end
  return nil
end

local function thread_query(entry)
  if not entry then return nil end
  if entry.thread then return 'thread:' .. entry.thread end
  if entry.message_id then return 'id:' .. entry.message_id end
  return nil
end

local function display_thread(item)
  local tags = item.tags or {}
  local unread = tbl_contains(tags, 'unread')
  local flagged = tbl_contains(tags, 'flagged') or tbl_contains(tags, 'starred')
  local date = item.timestamp and deck.time.format(item.timestamp, 'compact') or (item.date_relative or '')
  local authors = item.authors or '(unknown)'
  local subject = item.subject or '(no subject)'
  local tag_text = #tags > 0 and (' [' .. table.concat(tags, ' ') .. ']') or ''

  return deck.style.line {
    (unread and '● ' or '  '):fg(unread and 'green' or 'darkgray'),
    (flagged and '★ ' or '  '):fg(flagged and 'yellow' or 'darkgray'),
    (date .. '  '):fg 'yellow',
    authors:fg(unread and 'cyan' or 'blue'),
    '  ',
    subject:fg(unread and 'green' or 'white'),
    tag_text:fg 'darkgray',
  }
end

local function info_entry(key, title, message, detail, color)
  return setmetatable({
    key = key,
    kind = 'info',
    title = title,
    message = message,
    detail = detail,
    color = color or 'yellow',
    display = deck.style.line { title:fg(color or 'yellow'), ' ', (message or ''):fg 'darkgray' },
  }, {
    __index = {
      preview = function(e, cb)
        cb(deck.style.text {
          deck.style.line { (e.title or 'Info'):fg(e.color or 'yellow') },
          '',
          e.message or '',
          e.detail or '',
        })
      end,
    },
  })
end

local function check_deps()
  local deps = {
    notmuch = deck.system.executable('notmuch'),
    mbsync = deck.system.executable('mbsync'),
    msmtp = deck.system.executable('msmtp'),
  }
  state.deps = deps
  return deps
end

local function require_notmuch_entries()
  local deps = state.deps or check_deps()
  if deps.notmuch then return nil end
  return {
    info_entry('missing-notmuch', '缺少 notmuch', '请先安装并配置 notmuch。', '需要 `notmuch search/show/tag/new`。', 'red'),
  }
end

local function account_preview(entry, cb)
  cb(deck.style.text {
    deck.style.line { ('Account: '):fg 'cyan', tostring(entry.label or entry.key):fg 'green' },
    '',
    'Enter: 查看该账号 mailbox',
    'S: 同步所有账号',
    'c: 写新邮件，当前账号会作为默认发送账号',
    'g/: notmuch 搜索',
    '',
    entry.query and ('Query: ' .. entry.query) or '',
  })
end

local function mailbox_preview(entry, cb)
  cb(deck.style.text {
    deck.style.line { ('Mailbox: '):fg 'cyan', tostring(entry.label or entry.key):fg 'green' },
    entry.account and deck.style.line { ('Account: '):fg 'cyan', tostring(entry.account):fg 'yellow' } or '',
    '',
    'Enter: 打开邮件列表',
    'S: 同步',
    'c: 写新邮件',
    'g/: notmuch 搜索',
    '',
    entry.query and ('Query: ' .. entry.query) or '',
  })
end

local function attach_preview(entries, preview)
  for _, entry in ipairs(entries) do entry.preview = preview end
  return entries
end

local function count_key(scope, key)
  if scope and scope.account then return 'account:' .. scope.account .. ':' .. key end
  return 'global:' .. key
end

local function refresh_root_entries_if_visible(scope)
  local path = deck.api.get_current_path()
  if build_entries_for_current_root then
    if scope and scope.account then
      if #path == 2 and path[1] == 'notmuch' and path[2] == scope.account then
        deck.api.set_entries(nil, build_entries_for_current_root(false, scope))
      end
    else
      if #path == 1 and path[1] == 'notmuch' then
        deck.api.set_entries(nil, build_entries_for_current_root(false, nil))
      end
    end
  end
end

local function count_query(scope, key, query)
  local ck = count_key(scope, key)
  if state.count_pending[ck] then return end
  state.count_pending[ck] = true

  exec({ 'notmuch', 'count', '--output=threads', query }, function(out)
    state.count_pending[ck] = nil
    if out.code ~= 0 then return end

    local new_count = (out.stdout or ''):trim()
    local old_count = deck.cache.get('notmuch.lazydeck.counts', ck)
    deck.cache.set('notmuch.lazydeck.counts', ck, new_count, { ttl = 60 })
    if old_count ~= new_count then refresh_root_entries_if_visible(scope) end
  end)
end

local function build_account_entries(start_counts)
  local entries = {}
  for _, name in ipairs(ordered_accounts()) do
    local acc = cfg.accounts[name]
    local q = account_query(name, acc)
    local ck = count_key(nil, 'account-total:' .. name)
    local count = deck.cache.get('notmuch.lazydeck.counts', ck)
    local suffix = count and ('  ' .. tostring(count)) or ''
    table.insert(entries, {
      key = name,
      kind = 'account',
      account = name,
      label = acc.label or name,
      query = q,
      display = deck.style.line { (acc.label or name):fg 'cyan', suffix:fg 'yellow' },
      bottom_line = 'Enter 打开账号 | S 同步 | c 写信 | g/ 搜索',
    })
    if start_counts then count_query(nil, 'account-total:' .. name, q) end
  end

  table.insert(entries, {
    key = 'all-accounts',
    kind = 'mailbox',
    label = 'All Accounts',
    query = cfg.queries.all or '*',
    display = deck.style.line { ('All Accounts'):fg 'green' },
    bottom_line = 'Enter 查看所有账号邮件',
  })
  table.insert(entries, {
    key = 'search',
    kind = 'search',
    label = 'Search...',
    query = cfg.default_query,
    display = deck.style.line { ('Search...'):fg 'green' },
    bottom_line = 'Enter 输入 notmuch 查询',
  })
  return attach_preview(entries, account_preview)
end

local function build_mailbox_entries(start_counts, scope)
  local entries = {}
  for _, key in ipairs(cfg.order) do
    local query = scoped_query(scope, key)
    local count = deck.cache.get('notmuch.lazydeck.counts', count_key(scope, key))
    local label = cfg.labels[key] or key
    local suffix = count and ('  ' .. tostring(count)) or ''
    table.insert(entries, {
      key = key,
      kind = 'mailbox',
      account = scope and scope.account or nil,
      label = label,
      query = query,
      display = deck.style.line { label:fg 'cyan', suffix:fg 'yellow' },
      bottom_line = 'Enter 打开 | S 同步 | c 写信 | g/ 搜索',
    })
    if start_counts then count_query(scope, key, query) end
  end
  table.insert(entries, {
    key = 'search',
    kind = 'search',
    account = scope and scope.account or nil,
    label = 'Search...',
    query = scoped_query(scope, 'inbox'),
    display = deck.style.line { ('Search...'):fg 'green' },
    bottom_line = 'Enter 输入 notmuch 查询',
  })
  return attach_preview(entries, mailbox_preview)
end

build_entries_for_current_root = function(start_counts, scope)
  if has_accounts() and not scope then return build_account_entries(start_counts) end
  return build_mailbox_entries(start_counts, scope)
end

local function thread_entry(item, scope)
  local thread = item.thread or item.thread_id or item.key
  return setmetatable({
    key = thread,
    kind = 'thread',
    account = scope and scope.account or nil,
    thread = thread,
    subject = item.subject,
    authors = item.authors,
    timestamp = item.timestamp,
    tags = item.tags or {},
    display = display_thread(item),
    bottom_line = 'Enter 查看完整 thread | a 归档 | d 删除 | u 未读 | U 已读 | s 加星 | x 取消星 | r 回复',
  }, {
    __index = {
      keymap = thread_keymap,
      preview = function(e, cb) M.preview(e, cb) end,
    },
  })
end

local function list_threads(query, cb, scope)
  local missing = require_notmuch_entries()
  if missing then
    cb(missing)
    return
  end

  exec({ 'notmuch', 'search', '--format=json', '--output=summary', query }, function(out)
    if out.code ~= 0 then
      cb({ info_entry('search-error', 'notmuch search 失败', out.stderr or out.stdout or '', 'Query: ' .. query, 'red') })
      return
    end

    local data, err = parse_json(out.stdout)
    if not data then
      cb({ info_entry('json-error', 'JSON 解析失败', tostring(err), out.stdout or '', 'red') })
      return
    end

    local entries = {}
    for _, item in ipairs(data) do table.insert(entries, thread_entry(item, scope)) end
    if #entries == 0 then
      cb({ info_entry('empty', '没有邮件', 'Query: ' .. query, '', 'darkgray') })
    else
      cb(entries)
    end
  end)
end

local function list_thread(thread, cb, scope)
  cb({
    setmetatable({
      key = 'full',
      kind = 'thread-full',
      account = scope and scope.account or nil,
      thread = thread,
      display = deck.style.line { ('Thread '):fg 'cyan', tostring(thread):fg 'green' },
      bottom_line = 'a 归档 | d 删除 | u 未读 | U 已读 | s 加星 | x 取消星 | r 回复',
    }, {
      __index = {
        keymap = thread_keymap,
        preview = function(e, done) M.preview(e, done) end,
      },
    }),
  })
end

local function current_scope_for_action()
  local entry = deck.api.get_hovered()
  if entry and entry.account and cfg.accounts and cfg.accounts[entry.account] then
    return { account = entry.account, acc = cfg.accounts[entry.account] }
  end
  local path = deck.api.get_current_path()
  return scope_from_path(path)
end

local function refresh_after(out, success_msg)
  if out.code ~= 0 then
    notify_error('操作失败', out)
    return
  end
  state.preview_cache = {}
  state.preview_pending = {}
  if success_msg then deck.notify(success_msg) end
  deck.cmd('reload')
end

local function tag_current(tags, msg)
  local entry = deck.api.get_hovered()
  local q = thread_query(entry)
  if not q then
    deck.notify('请选择邮件 thread')
    return
  end
  local cmd = { 'notmuch', 'tag' }
  for _, tag in ipairs(tags) do table.insert(cmd, tag) end
  table.insert(cmd, q)
  exec(cmd, function(out) refresh_after(out, msg) end)
end

local function sync_mail()
  local deps = state.deps or check_deps()
  if not deps.mbsync then
    deck.notify('缺少 mbsync，无法同步')
    return
  end
  deck.notify('同步邮件中...')
  exec(cfg.sync_command, function(out)
    if out.code ~= 0 then
      notify_error('mbsync 失败', out)
      return
    end
    deck.notify('mbsync 完成，正在 notmuch new...')
    exec(cfg.notmuch_new_command, function(out2)
      if out2.code ~= 0 then
        notify_error('notmuch new 失败', out2)
        return
      end
      state.preview_cache = {}
      state.preview_pending = {}
      deck.notify('邮件同步完成')
      deck.cmd('reload')
    end)
  end)
end

local function open_search()
  local scope = current_scope_for_action()
  local default = scope and scoped_query(scope, 'inbox') or cfg.default_query
  deck.input {
    prompt = 'notmuch query: ',
    value = default,
    on_submit = function(input)
      if not input or input:trim() == '' then return end
      if scope and scope.account then
        deck.api.go_to({ 'notmuch', scope.account, 'search', input:trim() })
      else
        deck.api.go_to({ 'notmuch', 'search', input:trim() })
      end
    end,
  }
end

local function account_send_options(scope)
  local acc = scope and scope.acc or {}
  local from = acc.from or cfg.from or ''
  local sent_folder = cfg.sent_folder
  local msmtp_account = acc.msmtp_account
  local tags = { '+sent', '-inbox' }
  if acc.tag then table.insert(tags, '+' .. acc.tag) end
  return from, sent_folder, msmtp_account, tags
end

local function send_mail(content, source_path, scope)
  local deps = state.deps or check_deps()
  if not deps.msmtp then
    deck.notify('缺少 msmtp，无法发送；草稿保留在 ' .. tostring(source_path or '临时文件'))
    return
  end
  if not content or content:trim() == '' then
    deck.notify('空邮件，取消发送')
    return
  end

  local _, sent_folder, msmtp_account, sent_tags = account_send_options(scope)
  local msmtp_cmd = { 'msmtp' }
  if msmtp_account and msmtp_account ~= '' then
    table.insert(msmtp_cmd, '-a')
    table.insert(msmtp_cmd, msmtp_account)
  end
  table.insert(msmtp_cmd, '-t')

  deck.confirm {
    title = '发送邮件',
    prompt = '确认通过 ' .. table.concat(msmtp_cmd, ' ') .. ' 发送这封邮件？',
    on_confirm = function()
      exec_stdin(msmtp_cmd, content, function(out)
        if out.code ~= 0 then
          notify_error('发送失败，草稿已保留在 ' .. tostring(source_path or '临时文件'), out)
          return
        end
        deck.notify('邮件已发送')
        local insert_cmd = { 'notmuch', 'insert', '--create-folder', '--folder=' .. sent_folder }
        for _, tag in ipairs(sent_tags) do table.insert(insert_cmd, tag) end
        exec_stdin(insert_cmd, content, function(insert_out)
          if insert_out.code ~= 0 then notify_error('已发送，但写入 Sent 失败', insert_out) end
        end)
      end)
    end,
  }
end

local function compose()
  local scope = current_scope_for_action()
  local from = account_send_options(scope)
  local template = ''
  if from and from ~= '' then template = template .. 'From: ' .. from .. '\n' end
  template = template .. 'To: \nCc: \nBcc: \nSubject: \n\n'

  deck.system.edit({ content = template, ext = '.eml' }, function(content, err)
    if err then
      deck.notify('编辑失败: ' .. tostring(err))
      return
    end
    local path, path_err = deck.fs.tempfile({ prefix = 'lazydeck-mail-', suffix = '.eml', content = content or '' })
    if not path then
      deck.notify('保存临时草稿失败: ' .. tostring(path_err))
      return
    end
    send_mail(content, path, scope)
  end)
end

local function reply_current()
  local entry = deck.api.get_hovered()
  local q = thread_query(entry)
  if not q then
    deck.notify('请选择邮件 thread')
    return
  end
  local scope = current_scope_for_action()
  exec({ 'notmuch', 'reply', q }, function(out)
    if out.code ~= 0 then
      notify_error('notmuch reply 失败', out)
      return
    end
    deck.system.edit({ content = out.stdout or '', ext = '.eml' }, function(content, err)
      if err then
        deck.notify('编辑失败: ' .. tostring(err))
        return
      end
      local path, path_err = deck.fs.tempfile({ prefix = 'lazydeck-reply-', suffix = '.eml', content = content or '' })
      if not path then
        deck.notify('保存临时草稿失败: ' .. tostring(path_err))
        return
      end
      send_mail(content, path, scope)
    end)
  end)
end

local thread_actions = {
  archive = function() tag_current({ '-inbox' }, '已归档') end,
  trash = function() tag_current({ '+deleted', '-inbox' }, '已删除') end,
  unread = function() tag_current({ '+unread' }, '已标为未读') end,
  read = function() tag_current({ '-unread' }, '已标为已读') end,
  star = function() tag_current({ '+flagged' }, '已加星标') end,
  unstar = function() tag_current({ '-flagged' }, '已取消星标') end,
  reply = reply_current,
}

local function install_entry_keymaps()
  local km = cfg.keymap
  for k, _ in pairs(thread_keymap) do thread_keymap[k] = nil end
  if km.archive then thread_keymap[km.archive] = { callback = thread_actions.archive, desc = 'archive' } end
  if km.trash then thread_keymap[km.trash] = { callback = thread_actions.trash, desc = 'trash/delete' } end
  if km.unread then thread_keymap[km.unread] = { callback = thread_actions.unread, desc = 'mark unread' } end
  if km.read then thread_keymap[km.read] = { callback = thread_actions.read, desc = 'mark read' } end
  if km.star then thread_keymap[km.star] = { callback = thread_actions.star, desc = 'star/flag' } end
  if km.unstar then thread_keymap[km.unstar] = { callback = thread_actions.unstar, desc = 'unstar/unflag' } end
  if km.reply then thread_keymap[km.reply] = { callback = thread_actions.reply, desc = 'reply' } end
end

function M.setup(opt)
  cfg = deck.tbl_deep_extend('force', cfg, opt or {})
  check_deps()
  install_entry_keymaps()

  local km = cfg.keymap
  if km.sync then deck.keymap.set('main', km.sync, sync_mail, { desc = 'mail sync' }) end
  if km.compose then deck.keymap.set('main', km.compose, compose, { desc = 'compose mail' }) end
  if km.search then deck.keymap.set('main', km.search, open_search, { desc = 'notmuch search' }) end
end

function M.meta()
  return {
    icon = '󰇮',
    desc = 'Mail client powered by notmuch/isync/msmtp',
    color = 'cyan',
  }
end

function M.list(path, cb)
  if #path == 1 then
    local missing = require_notmuch_entries()
    if missing then
      cb(missing)
      return
    end
    cb(build_entries_for_current_root(true, nil))
    return
  end

  -- multi-account root: /notmuch/<account>
  local scope = scope_from_path(path)
  if scope and #path == 2 then
    cb(build_entries_for_current_root(true, scope))
    return
  end

  -- /notmuch/search/<query>
  if path[2] == 'search' then
    if not path[3] then
      open_search()
      cb({ info_entry('search', '输入 notmuch 查询', '已打开搜索输入框。', '', 'green') })
    else
      list_threads(path[3], cb, nil)
    end
    return
  end

  -- /notmuch/all-accounts
  if has_accounts() and path[2] == 'all-accounts' then
    list_threads(cfg.queries.all or '*', cb, nil)
    return
  end

  -- /notmuch/<account>/search/<query>
  if scope and path[3] == 'search' then
    if not path[4] then
      open_search()
      cb({ info_entry('search', '输入 notmuch 查询', '已打开搜索输入框。', '', 'green') })
    else
      list_threads(path[4], cb, scope)
    end
    return
  end

  -- /notmuch/<account>/<mailbox>
  if scope and path[3] then
    local key = path[3]
    if cfg.queries[key] then
      list_threads(scoped_query(scope, key), cb, scope)
    else
      list_thread(key, cb, scope)
    end
    return
  end

  -- legacy global /notmuch/<mailbox>
  if cfg.queries[path[2]] then
    list_threads(cfg.queries[path[2]], cb, nil)
    return
  end

  -- legacy /notmuch/<mailbox>/<thread>
  if #path >= 3 then
    list_thread(path[#path], cb, nil)
    return
  end

  cb({ info_entry('unknown', '未知路径', table.concat(path, '/'), '', 'red') })
end

function M.preview(entry, cb)
  if not entry then
    cb('No entry')
    return
  end
  if entry.kind == 'account' then
    account_preview(entry, cb)
    return
  end
  if entry.kind == 'mailbox' or entry.kind == 'search' then
    mailbox_preview(entry, cb)
    return
  end
  if entry.kind == 'info' then
    cb(entry.message or '')
    return
  end

  local q = thread_query(entry)
  if not q then
    cb('No thread selected')
    return
  end

  if state.preview_cache[q] then
    cb(state.preview_cache[q])
    return
  end
  if state.preview_pending[q] then
    -- 已经有同一个 notmuch show 在跑，避免重复回调导致预览闪烁。
    table.insert(state.preview_pending[q], cb)
    return
  end

  state.preview_pending[q] = { cb }
  cb('Loading mail preview...')
  exec({ 'notmuch', 'show', '--format=text', '--entire-thread=true', q }, function(out)
    local result
    if out.code ~= 0 then
      result = 'notmuch show failed:\n' .. (out.stderr or out.stdout or '')
    else
      result = out.stdout or ''
      state.preview_cache[q] = result
    end
    local callbacks = state.preview_pending[q] or {}
    state.preview_pending[q] = nil
    for _, done in ipairs(callbacks) do
      done(result)
    end
  end)
end

return M
