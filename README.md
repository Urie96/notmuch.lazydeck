# notmuch.lazydeck

一个基于 `notmuch` / `mbsync` / `msmtp` 的 lazydeck 邮件插件。

插件本身不实现 IMAP/SMTP 协议：

- `mbsync` / `isync` 负责同步邮件到本地 Maildir
- `notmuch` 负责索引、搜索、标签和线程查询
- `msmtp` 负责发送邮件
- lazydeck 插件负责 TUI 列表、预览、快捷键和调用外部命令

## 依赖

必需命令：

```bash
notmuch
mbsync
msmtp
```

插件启动时会检查这些命令是否存在。

## 基本配置

在 `~/.config/lazydeck/init.lua` 中添加：

```lua
{
  'urie96/notmuch.lazydeck',
  config = function()
    require('notmuch').setup {
      accounts = {
        {
          name = 'all',
          label = 'All',
          query = '*',
        },
        {
          name = 'qq',
          label = 'QQ',
          query = 'tag:account-qq',
          msmtp_account = 'qq',
        },
        {
          name = 'gmail',
          label = 'Gmail',
          query = 'path:gmail/**',
          msmtp_account = 'gmail',
        },
      },
    }
  end,
}
```

## 账号配置

`accounts` 是数组，显示顺序就是数组顺序。

每个账号支持字段：

| 字段 | 必需 | 说明 |
|---|---:|---|
| `name` | 是 | 账号内部 ID，用于路径，例如 `/notmuch/qq` |
| `label` | 否 | UI 显示名；不填则显示 `name` |
| `query` | 否 | 账号对应的 notmuch query；不填时默认 `path:<name>/**` |
| `msmtp_account` | 否 | 发送邮件时使用的 msmtp 账号，即 `msmtp -a <account> -t` |

### `name`

`name` 是稳定的内部标识，建议使用简单 ASCII 字符串：

```lua
name = 'qq'
name = 'gmail'
name = 'work'
name = 'personal'
```

它会用于 lazydeck 路径：

```text
/notmuch/qq
/notmuch/qq/inbox
/notmuch/qq/search/<query>
```

### `label`

`label` 只影响显示：

```lua
{
  name = 'work',
  label = '工作邮箱',
  query = 'tag:account-work',
}
```

### `query`

`query` 是区分账号的核心。插件不限定用户必须用 tag，也可以用 path、folder 或任意 notmuch query。

用 tag 区分：

```lua
{
  name = 'qq',
  label = 'QQ',
  query = 'tag:account-qq',
}
```

用路径区分：

```lua
{
  name = 'gmail',
  label = 'Gmail',
  query = 'path:gmail/**',
}
```

用更复杂的 query：

```lua
{
  name = 'work',
  label = 'Work',
  query = '(to:me@company.com or from:me@company.com)',
}
```

如果不写 `query`，插件会默认使用：

```text
path:<name>/**
```

例如：

```lua
{ name = 'qq' }
```

等价于：

```lua
{ name = 'qq', query = 'path:qq/**' }
```

### `msmtp_account`

发送邮件时使用：

```lua
msmtp_account = 'qq'
```

对应命令：

```bash
msmtp -a qq -t
```

如果不配置 `msmtp_account`，发送时使用：

```bash
msmtp -t
```

也就是 msmtp 的默认账号。

## Mailbox 查询规则

进入某个账号后，插件会基于账号的 `query` 自动派生 mailbox：

假设账号配置：

```lua
{
  name = 'qq',
  query = 'tag:account-qq',
}
```

则：

| 页面 | notmuch query |
|---|---|
| `/notmuch/qq/inbox` | `(tag:account-qq) and tag:inbox and not tag:deleted` |
| `/notmuch/qq/unread` | `(tag:account-qq) and tag:unread and not tag:deleted` |
| `/notmuch/qq/starred` | `(tag:account-qq) and tag:flagged and not tag:deleted` |
| `/notmuch/qq/sent` | `(tag:account-qq) and tag:sent` |
| `/notmuch/qq/archive` | `(tag:account-qq) and not tag:inbox and not tag:deleted` |
| `/notmuch/qq/trash` | `(tag:account-qq) and tag:deleted` |
| `/notmuch/qq/all` | `tag:account-qq` |

因此插件只要求 notmuch 标签/查询语义正确，不关心你的 Maildir 具体目录结构。

## 添加 All 账号

插件没有内置特殊的 `All Accounts` 页面。如果需要全部邮件视图，直接配置一个普通账号：

```lua
{
  name = 'all',
  label = 'All',
  query = '*',
}
```

对应路径：

```text
/notmuch/all
/notmuch/all/inbox
/notmuch/all/all
```

## 自动打账号标签示例

如果你想用 tag 区分账号，可以用 notmuch hook 自动打标。

创建：

```text
~/.notmuch/hooks/post-new
```

示例：

```bash
#!/usr/bin/env bash
set -euo pipefail

notmuch tag +account-qq -- 'path:qq/** and not tag:account-qq'
notmuch tag +account-gmail -- 'path:gmail/** and not tag:account-gmail'
notmuch tag +account-work -- 'path:work/** and not tag:account-work'
```

加执行权限：

```bash
chmod +x ~/.notmuch/hooks/post-new
```

之后每次执行：

```bash
notmuch new
```

都会自动按路径添加账号标签。

## 页面结构

```text
/notmuch
  all
  qq
  gmail

/notmuch/<account>
  inbox
  unread
  starred
  sent
  archive
  trash
  all
  search
```

示例：

```text
/notmuch/qq/inbox
/notmuch/qq/trash
/notmuch/gmail/sent
/notmuch/all/all
```

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `S` | 同步邮件：`mbsync -a` 后执行 `notmuch new` |
| `c` | 写新邮件 |
| `g/` | 输入 notmuch query 搜索 |
| `a` | 归档当前 thread：`notmuch tag -inbox` |
| `d` | 删除当前 thread：`notmuch tag +deleted -inbox` |
| `u` | 当前 thread 标记已读：`notmuch tag -unread` |
| `U` | 当前列表全部标记已读：`notmuch tag -unread <当前列表 query>` |
| `s` | 当前 thread 加星标：`notmuch tag +flagged` |
| `x` | 当前 thread 取消星标：`notmuch tag -flagged` |
| `r` | 回复当前 thread |

## 发送邮件

写新邮件或回复时，插件会打开 `$EDITOR` 编辑 `.eml` 模板，确认后调用：

```bash
msmtp -t
```

如果当前账号配置了 `msmtp_account`，则调用：

```bash
msmtp -a <msmtp_account> -t
```

发送成功后，插件会尝试保存一份发送副本：

```bash
notmuch insert --create-folder --folder=Sent +sent -inbox
```

注意：发送副本目前只打通用 `+sent -inbox` 标签，不会额外打账号标签。账号归属应由你的 notmuch hook 或 query 规则处理。

## 常用配置项

```lua
require('notmuch').setup {
  accounts = {
    {
      name = 'all',
      label = 'All',
      query = '*',
    },
    {
      name = 'qq',
      label = 'QQ',
      query = 'tag:account-qq',
      msmtp_account = 'qq',
    },
  },

  sync_command = { 'mbsync', '-a' },
  notmuch_new_command = { 'notmuch', 'new' },
  sent_folder = 'Sent',

  keymap = {
    sync = 'S',
    compose = 'c',
    search = 'g/',
    archive = 'a',
    trash = 'd',
    read = 'u',
    read_all = 'U',
    star = 's',
    unstar = 'x',
    reply = 'r',
  },
}
```

## 设计原则

- 插件不假设账号一定由 tag 区分。
- 插件只依赖每个账号的 notmuch `query`。
- Inbox/Sent/Trash/Unread 等语义由 notmuch 标签决定。
- Maildir 目录结构和打标规则由用户自己的 notmuch/isync 配置管理。
