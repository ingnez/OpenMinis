//
//  CloudDesktopFakePage.swift
//  Minis - 只给模拟器端到端测试：云电脑画面页里的 noVNC 换成假 RFB
//

import Foundation

/// 模拟器上没有 Xvfb / x11vnc：把画面页里 `import('./core/rfb.js')` 换成一个假 RFB。
/// 它画一张 1280×800 的格子图（按比例居中，和 noVNC 的 scaleViewport 一样），连上后照常发 connect，
/// App 发来的指针原样回报（type: fakeptr，远端像素 + 按键掩码），测试据此核对「放大后点到哪、远端就收到哪」。
/// 只在 CloudE2E.fakeDesktop（Debug + 测试环境变量）时用到，正式包里这条路径不会走。
enum CloudDesktopFakePage {
    static let realImport = "try { RFB = (await import('./core/rfb.js')).default; } catch (e) { post('nomodule'); }"

    static let fakeRFB = """
    RFB = class {
      constructor(target) {
        this._l = {}; this.viewOnly = false; this.qualityLevel = 6; this.compressionLevel = 2; this.scaleViewport = true;
        const c = this._c = document.createElement('canvas'); c.width = 1280; c.height = 800; c.style.position = 'absolute';
        target.appendChild(c);
        this._fit = () => {
          const W = target.clientWidth, H = target.clientHeight, r = Math.min(W / 1280, H / 800);
          c.style.width = (1280 * r) + 'px'; c.style.height = (800 * r) + 'px';
          c.style.left = ((W - 1280 * r) / 2) + 'px'; c.style.top = ((H - 800 * r) / 2) + 'px';
        };
        window.addEventListener('resize', this._fit); this._fit(); this._draw();
        setTimeout(() => this._emit('connect', {}), 150);
      }
      addEventListener(n, f) { (this._l[n] = this._l[n] || []).push(f); }
      _emit(n, d) { (this._l[n] || []).forEach(f => { try { f({ detail: d }); } catch (e) {} }); }
      _draw() {
        const g = this._c.getContext('2d');
        g.fillStyle = '#1d2733'; g.fillRect(0, 0, 1280, 800);
        g.strokeStyle = '#3a4a5c'; g.lineWidth = 1; g.fillStyle = '#8aa'; g.font = '14px sans-serif';
        for (let x = 0; x <= 1280; x += 80) { g.beginPath(); g.moveTo(x, 0); g.lineTo(x, 800); g.stroke(); g.fillText(String(x), x + 3, 14); }
        for (let y = 0; y <= 800; y += 80) { g.beginPath(); g.moveTo(0, y); g.lineTo(1280, y); g.stroke(); g.fillText(String(y), 3, y - 3); }
        g.fillStyle = '#e8eef5'; g.font = 'bold 40px sans-serif'; g.fillText('E2E 假云电脑 1280×800', 380, 400);
        if (this._click) {
          const [x, y] = this._click;
          g.strokeStyle = '#ff4d4f'; g.lineWidth = 3;
          g.beginPath(); g.arc(x, y, 14, 0, Math.PI * 2); g.moveTo(x - 24, y); g.lineTo(x + 24, y); g.moveTo(x, y - 24); g.lineTo(x, y + 24); g.stroke();
          g.fillStyle = '#ff4d4f'; g.font = '16px sans-serif'; g.fillText('点击 ' + x + ',' + y, x + 18, y - 18);
        }
      }
      _sendMouse(x, y, mask) {
        if (mask) { this._click = [x, y]; this._draw(); }
        window.om && om.send({ type: 'fakeptr', x: x, y: y, mask: mask });
      }
      sendKey() {}
      clipboardPasteFrom() {}
      disconnect() { this._emit('disconnect', { clean: true }); }
    };
    """

    /// 换掉真 noVNC 的加载；页面结构变了找不到那一行就原样返回（测试会因为连不上而失败，不会悄悄走真页面）
    static func patch(_ html: String) -> String {
        html.replacingOccurrences(of: realImport, with: fakeRFB)
    }
}
