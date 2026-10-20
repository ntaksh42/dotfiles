import type { Register } from 'claude-code'

import { classicSessionStart as linkBarClassicSessionStart, register as adoLinkBar, sessionStart as linkBarSessionStart } from './ado-link-bar/register'
import { commandRunRename as titleCommandRunRename, register as autoSessionTitle, sessionStart as titleSessionStart } from './auto-session-title/register'
import { register as cmdHistory, sessionStart as cmdHistorySessionStart } from './cmdHistory/register'
import {
  classicSessionStart as toastClassicSessionStart,
  commandRunRename as toastCommandRunRename,
  register as toastNotify,
  sessionStart as toastSessionStart,
  turnComplete as toastTurnComplete,
} from './toast-notify/register'

// The engine accepts one unmatched hook per event per plugin, so mods that share an event are nested here.

export const register: Register = (on, options) => {
  on('session.start', ($, e, next) =>
    linkBarSessionStart($, e, (e1 => titleSessionStart($, e1, (e2 => cmdHistorySessionStart($, e2, (e3 => toastSessionStart($, e3, next)) as never)) as never)) as never))
  on('turn.complete', toastTurnComplete)
  on('classic.SessionStart', ($, e, next) =>
    linkBarClassicSessionStart($, e, (e1 => toastClassicSessionStart($, e1, next)) as never))
  on('command.run', { command: 'rename' }, ($, e, next) =>
    titleCommandRunRename($, e, (e1 => toastCommandRunRename($, e1, next)) as never))
  adoLinkBar(on, options)
  autoSessionTitle(on, options)
  cmdHistory(on, options)
  toastNotify(on, options)
}
