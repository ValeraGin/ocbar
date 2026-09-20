#!/usr/bin/env python3
"""Маскировка отчёта: текст со стандартного ввода — на стандартный вывод.

Скрывает домашний каталог, логин, адреса, домены, почту и cookie. Имена
файлов, версии и собственные идентификаторы ocbar не трогает.
Окружение: OCBAR_R_HOME, OCBAR_R_USER.
"""
import os, re, sys
t = sys.stdin.read()
home, user = os.environ.get('OCBAR_R_HOME', ''), os.environ.get('OCBAR_R_USER', '')
if home: t = t.replace(home, '~')
if user: t = re.sub(r'\b' + re.escape(user) + r'\b', '<логин>', t)
t = re.sub(r'(?i)\b(cookie|token|secret|password|пароль)\s*[:=]\s*\S+', r'\1=<скрыто>', t)
t = re.sub(r'https?://\S+', 'https://<шлюз>', t)
def ip(m):
    a = m.group(0)
    return a if a.startswith(('127.', '0.0.0.0', '255.')) else '<адрес>'
t = re.sub(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', ip, t)
t = re.sub(r'\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b', '<почта>', t)
t = re.sub(r'(?m)^(\s*(?:User|user|Пользователь)\s*[:=]\s*).+$', r'\1<логин>', t)
# Имена файлов и каталогов доменами не считаем: иначе supervisor.log и
# ocbar.app превращались в <домен> и отчёт становился нечитаемым.
skip = 'log|app|md|sh|swift|rb|png|json|conf|ocbar|rules|plist|yml|txt|state|env|pid|bak|bundle|icns|html|tmp|py|example|local|test|1'
def host(m):
    h = m.group(0)
    if h.lower().startswith(('ru.ocbar', 'ocbar.')): return h
    last = h.rsplit('.', 1)[-1].lower()
    if last in skip.split('|') or not last.isalpha() or len(last) < 2:
        return h
    return '<домен>'
t = re.sub(r'(?<![\w/.-])[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)+\b', host, t, flags=re.I)
sys.stdout.write(t)
