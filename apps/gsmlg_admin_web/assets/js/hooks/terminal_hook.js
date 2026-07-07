/**
 * Terminal Hook for PTY Session Integration
 *
 * Integrates xterm.js with Phoenix LiveView for interactive terminal sessions.
 * Handles bidirectional communication with PTY agents via Phoenix channels.
 */

import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { WebLinksAddon } from '@xterm/addon-web-links';
import { Socket } from 'phoenix';

export const TerminalHook = {
  mounted() {
    const sessionId = this.el.dataset.sessionId;
    const agentId = this.el.dataset.agentId;
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute('content');

    // Initialize terminal
    this.terminal = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: 'Menlo, Monaco, "Courier New", monospace',
      theme: {
        background: '#1e1e1e',
        foreground: '#d4d4d4',
        cursor: '#d4d4d4',
        black: '#000000',
        red: '#cd3131',
        green: '#0dbc79',
        yellow: '#e5e510',
        blue: '#2472c8',
        magenta: '#bc3fbc',
        cyan: '#11a8cd',
        white: '#e5e5e5',
        brightBlack: '#666666',
        brightRed: '#f14c4c',
        brightGreen: '#23d18b',
        brightYellow: '#f5f543',
        brightBlue: '#3b8eea',
        brightMagenta: '#d670d6',
        brightCyan: '#29b8db',
        brightWhite: '#ffffff'
      },
      scrollback: 10000,
      allowTransparency: false,
      convertEol: true
    });

    // Initialize addons
    this.fitAddon = new FitAddon();
    this.webLinksAddon = new WebLinksAddon();

    this.terminal.loadAddon(this.fitAddon);
    this.terminal.loadAddon(this.webLinksAddon);

    // Open terminal in container
    this.terminal.open(this.el);
    this.fitAddon.fit();

    // Handle terminal resize
    const resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit();
      const dims = this.fitAddon.proposeDimensions();
      if (dims && this.channel) {
        this.sendResize(dims.rows, dims.cols);
      }
    });
    resizeObserver.observe(this.el);
    this.resizeObserver = resizeObserver;

    // Handle window resize
    this.windowResizeHandler = () => {
      this.fitAddon.fit();
    };
    window.addEventListener('resize', this.windowResizeHandler);

    // Connect to Phoenix channel
    this.connectChannel(sessionId, agentId, csrfToken);

    // Handle terminal input
    this.terminal.onData((data) => {
      if (this.channel && this.attached) {
        // Use 'input' event for operator channel
        this.channel.push('input', { data: data });
      }
    });

    // Notify LiveView of mount
    this.pushEvent('terminal_mounted', { session_id: sessionId });

    // Handle LiveView events
    this.handleEvent('terminal_output', ({ data }) => {
      this.terminal.write(data);
    });

    this.handleEvent('terminal_closed', ({ exit_code }) => {
      this.terminal.write(`\r\n\r\n[Process exited with code ${exit_code}]\r\n`);
      this.terminal.setOption('disableStdin', true);
    });

    this.handleEvent('terminal_error', ({ message }) => {
      this.terminal.write(`\r\n\x1b[1;31m[Error: ${message}]\x1b[0m\r\n`);
    });

    this.handleEvent('attach', () => {
      this.attached = true;
      this.terminal.write('\r\n\x1b[1;32m[Session attached]\x1b[0m\r\n');
    });

    this.handleEvent('detach', () => {
      this.attached = false;
      this.terminal.write('\r\n\x1b[1;33m[Session detached]\x1b[0m\r\n');
      this.terminal.setOption('disableStdin', true);
    });
  },

  updated() {
    // Handle any updates if needed
  },

  destroyed() {
    // Cleanup
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }

    if (this.windowResizeHandler) {
      window.removeEventListener('resize', this.windowResizeHandler);
    }

    if (this.channel) {
      this.channel.leave();
    }

    if (this.terminal) {
      this.terminal.dispose();
    }
  },

  connectChannel(sessionId, agentId, csrfToken) {
    const socket = new Socket('/socket', {
      params: { _csrf_token: csrfToken }
    });

    socket.connect();

    // Join operator terminal channel for the PTY session.
    this.channel = socket.channel(`operator:terminal:${sessionId}`, { agent_id: agentId });

    this.channel
      .join()
      .receive('ok', (resp) => {
        console.log('Joined operator terminal channel', resp);
        this.attached = true;
        this.terminal.focus();
        this.terminal.write('\x1b[1;32mConnected to terminal.\x1b[0m\r\n');
      })
      .receive('error', (resp) => {
        console.error('Failed to join operator terminal channel', resp);
        this.terminal.write('\r\n\x1b[1;31m[Error: Failed to connect to session - ' + (resp.reason || 'unknown') + ']\x1b[0m\r\n');
      });

    // Handle messages from channel
    this.channel.on('output', ({ data }) => {
      // Data comes base64 encoded from the operator channel
      try {
        const decoded = atob(data);
        this.terminal.write(decoded);
      } catch (e) {
        // If not base64, write directly
        this.terminal.write(data);
      }
    });

    this.channel.on('session_closed', ({ exit_code }) => {
      this.terminal.write(`\r\n\r\n[Process exited with code ${exit_code}]\r\n`);
      this.terminal.setOption('disableStdin', true);
      this.pushEvent('session_closed', { session_id: sessionId, exit_code: exit_code });
    });

    this.channel.on('error', ({ message }) => {
      this.terminal.write(`\r\n\x1b[1;31m[Error: ${message}]\x1b[0m\r\n`);
    });

    this.channel.on('resized', ({ rows, cols }) => {
      console.log(`Terminal resized to ${rows}x${cols}`);
    });

    // Legacy event handlers for backward compatibility
    this.channel.on('pty_output', ({ data }) => {
      this.terminal.write(data);
    });

    this.channel.on('pty_closed', ({ exit_code }) => {
      this.terminal.write(`\r\n\r\n[Process exited with code ${exit_code}]\r\n`);
      this.terminal.setOption('disableStdin', true);
      this.pushEvent('session_closed', { session_id: sessionId, exit_code: exit_code });
    });

    this.channel.on('pty_error', ({ message }) => {
      this.terminal.write(`\r\n\x1b[1;31m[Error: ${message}]\x1b[0m\r\n`);
    });

    this.channel.on('pty_resized', ({ rows, cols }) => {
      console.log(`Terminal resized to ${rows}x${cols}`);
    });

    this.socket = socket;
  },

  sendResize(rows, cols) {
    if (this.channel) {
      this.channel.push('resize', { rows: rows, cols: cols });
    }
  }
};

export default TerminalHook;
