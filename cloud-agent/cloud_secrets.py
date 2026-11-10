#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent 加密凭据存储 (cloud_secrets.py)

- AES-256-GCM（cryptography 库的 AESGCM，不自行实现任何密码算法）
- 主密钥来源优先级：环境变量 OPENMINIS_MASTER_KEY（base64 32 字节）> 主密钥文件
  OPENMINIS_MASTER_KEY_FILE（默认 /etc/openminis/master.key，必须 600 权限）
- 主密钥文件不存在且所在目录可写时自动生成（O_EXCL + 0600）；systemd 下 /etc 只读，
  由 install.sh 预先生成
- 每条密文绑定 AAD（如 "credential:<name>"），密文不能在不同记录间挪用
- 密文格式：b"v1" + 12 字节随机 nonce + 密文与 16 字节 tag
- 依赖缺失或密钥不可用时明确报告不可用，绝不回退为明文存储
"""

import os
import base64
import secrets
import threading

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    crypto_available = True
except Exception:  # pragma: no cover - 取决于 VPS 环境
    AESGCM = None
    crypto_available = False

DEFAULT_KEY_FILE = "/etc/openminis/master.key"
FORMAT_PREFIX = b"v1"
NONCE_BYTES = 12


class SecretStoreUnavailable(Exception):
    """加密存储不可用（缺少 cryptography 或主密钥）。"""


class SecretDecryptError(Exception):
    """密文损坏、被篡改或主密钥已更换。"""


def _decode_key(text):
    try:
        raw = base64.b64decode(text.strip(), validate=True)
    except Exception:
        raise SecretStoreUnavailable("主密钥不是有效的 base64")
    if len(raw) != 32:
        raise SecretStoreUnavailable("主密钥长度必须为 32 字节 (AES-256)")
    return raw


def _load_key_file(path, autocreate):
    if not os.path.exists(path):
        if not autocreate:
            raise SecretStoreUnavailable(f"主密钥文件不存在：{path}")
        directory = os.path.dirname(os.path.abspath(path))
        try:
            os.makedirs(directory, exist_ok=True)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        except OSError as e:
            raise SecretStoreUnavailable(f"无法创建主密钥文件 {path}：{e.strerror}")
        else:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(base64.b64encode(secrets.token_bytes(32)).decode("ascii") + "\n")
    st = os.stat(path)
    if st.st_mode & 0o077:
        raise SecretStoreUnavailable("主密钥文件权限必须为 600")
    with open(path, "r", encoding="utf-8") as f:
        return _decode_key(f.read())


class SecretBox:
    def __init__(self, key_bytes):
        if not crypto_available:
            raise SecretStoreUnavailable("缺少 Python cryptography 库，无法加密保存凭据")
        self._aead = AESGCM(key_bytes)

    def encrypt(self, plaintext, aad):
        if not isinstance(plaintext, str):
            raise TypeError("plaintext must be str")
        nonce = secrets.token_bytes(NONCE_BYTES)
        ct = self._aead.encrypt(nonce, plaintext.encode("utf-8"), aad.encode("utf-8"))
        return FORMAT_PREFIX + nonce + ct

    def decrypt(self, blob, aad):
        if not isinstance(blob, (bytes, bytearray)) or not bytes(blob).startswith(FORMAT_PREFIX):
            raise SecretDecryptError("未知密文格式")
        blob = bytes(blob)
        nonce = blob[len(FORMAT_PREFIX):len(FORMAT_PREFIX) + NONCE_BYTES]
        ct = blob[len(FORMAT_PREFIX) + NONCE_BYTES:]
        try:
            return self._aead.decrypt(nonce, ct, aad.encode("utf-8")).decode("utf-8")
        except Exception:
            raise SecretDecryptError("凭据解密失败：密文被篡改或主密钥已更换")


_box = None
_box_error = None
_box_lock = threading.Lock()


def reset():
    """测试或配置变更后重新加载主密钥。"""
    global _box, _box_error
    with _box_lock:
        _box = None
        _box_error = None


def get_box():
    """返回进程级 SecretBox；不可用时抛出 SecretStoreUnavailable。"""
    global _box, _box_error
    with _box_lock:
        if _box is not None:
            return _box
        try:
            env_key = os.environ.get("OPENMINIS_MASTER_KEY")
            if env_key:
                key = _decode_key(env_key)
            else:
                path = os.environ.get("OPENMINIS_MASTER_KEY_FILE", DEFAULT_KEY_FILE)
                autocreate = os.environ.get("OPENMINIS_MASTER_KEY_AUTOCREATE", "1") != "0"
                key = _load_key_file(path, autocreate)
            _box = SecretBox(key)
            _box_error = None
            return _box
        except SecretStoreUnavailable as e:
            _box_error = str(e)
            raise


def status():
    """(available: bool, reason: str|None)，供 /health 报告。"""
    try:
        get_box()
        return True, None
    except SecretStoreUnavailable as e:
        return False, str(e)
