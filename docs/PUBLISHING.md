# Публикация на GitHub

## Что понадобится от владельца

1. Решение по лицензии: MIT, Apache-2.0 или исходный код без открытой лицензии.
2. Для публичного бинарника — сертификат Apple Developer ID Application и
   данные notarytool. Текущая ad-hoc подпись подходит для локальной проверки,
   но не заменяет notarization.

## Проверка исходников

```bash
./build.sh test
./build.sh
codesign --verify --deep --strict dist/голос.app
```

До первого push убедитесь, что `git status` не содержит `.build`, `dist`,
модели, записи, журналы или пользовательский `settings.json`.

## Первый push

```bash
git init
git add .
git commit -m "Initial public release"
git branch -M main
git remote add origin https://github.com/bantqn/golos.git
git push -u origin main
```

Репозиторий проекта: <https://github.com/bantqn/golos>.

## Бинарный релиз

После подписи Developer ID и notarization:

```bash
ditto -c -k --sequesterRsrc --keepParent dist/голос.app голос-1.0-macOS.zip
shasum -a 256 голос-1.0-macOS.zip > голос-1.0-macOS.zip.sha256
```

Создайте тег `v1.0.0`, вставьте текст из `RELEASE_NOTES.md`, приложите ZIP и
SHA-256. Инфографика уже находится в `docs/assets/overview.svg`, логотип и три
направления — в `docs/BRAND.md`.

## Финальная проверка страницы

- README начинается с логотипа и инфографики, изображения открываются без LFS;
- системные требования и разрешения видны до длинного технического раздела;
- release notes не обещают облачных функций и явно говорят о локальной работе;
- SECURITY содержит реальный приватный контакт;
- выбранная лицензия добавлена файлом `LICENSE`;
- архив скачивается на чистом Mac, проходит Gatekeeper и первый запуск.
