# OpenGlasses — Checklist Build 2º Ray-Ban (host: MBA)
_Gerado 2026-07-21 após auditoria completa. Conta Apple GRÁTIS confirmada._

## No portal Meta (wearables.developer.meta.com → RayBan Meta → Configuration)
- [ ] **Bundle ID**: mudar `com.straff…` → `com.openglasses.app` e SALVAR (repo é uniformemente com.openglasses.app)
- [x] Team ID 8M4N6TK… (já bate)
- [x] Universal link https://g2-ai.rochasilva.co.uk (já setado)
- [x] MetaAppID 3396315787208253 + ClientToken → já no keychain M2+M4 (meta-wearables-app-id / meta-wearables-client-token)

## No app Meta AI (iPhone)
- [ ] Parear o 2º Ray-Ban
- [ ] Developer Mode: Settings → About → tocar versão 5×
- [ ] Registrar novo device no Wearables Dev Center (liberar o queimado)

## No MBA (Xcode — NUNCA no M4, só tem CommandLineTools)
- [ ] `cd ~/repos/OpenGlasses && git pull`
- [ ] `OPENGLASSES_SKIP_WATCH=1 OPENGLASSES_SKIP_TESTS=1 ./Scripts/setup-local-dev.sh --team 8M4N6TKXG7 com.openglasses.app` (não recuperar o team upstream B9… do histórico)
- [x] O template pessoal agora contém só `application-groups`; não precisa remover HomeKit/increased-memory à mão
- [ ] Colar MetaAppID+ClientToken no `Config/Info/Info.personal.plist` (seção MWDAT) — valores no keychain
- [ ] `brew install xcodegen` (se faltar)
- [ ] `OPENGLASSES_SKIP_WATCH=1 OPENGLASSES_SKIP_TESTS=1 ./Scripts/generate-xcodeproj.sh` (poupa App IDs no limite free 10/7d)
- [ ] `open OpenGlasses.xcodeproj` → assinar com Apple ID grátis → ⌘R no iPhone plugado

## Associated Domains
- [x] Projeto principal: `applinks:g2-ai.rochasilva.co.uk` restaurado em `project.base.yml` e `OpenGlasses.entitlements`
- [x] AASA do bridge: inclui `8M4N6TKXG7.com.openglasses.app`
- [ ] Conta gratuita: manter Associated Domains fora de `Config/Entitlements/Personal/OpenGlasses.entitlements`; Personal Team não recebe esse entitlement e o build falha se ele for incluído
- [ ] Para Universal Link nativo: assinar com Apple Developer Program pago e usar o entitlement principal; até lá, continuar com o callback/esquema que já funciona

## Perfil de 7 dias
- [ ] Perfil atual expira em 31/07/2026 às 13:31; o rebuild de 24/07 reutilizou o perfil e não mudou a validade
- [ ] Reprovisionar e reinstalar pelo Xcode no MBA quando o perfil expirar (ou remover apenas esse perfil no MBA antes de recompilar para forçar emissão nova)
- [ ] Alternativa durável: Apple Developer Program pago; AltStore/SideStore continua sendo alternativa operacional, não correção do projeto

## Perde no free tier (aceitável)
- HomeKit (usa REST do HA pelos óculos), CarPlay, modelos locais grandes (increased-memory-limit). Claude/Gemini via API: OK.
- Cert expira em 7 dias → reinstalar via Xcode, ou montar AltStore/SideStore p/ auto-refresh.
