# Phase 1 release templates

Worker uses Mix's stock VM/environment templates in this directory. Management
uses `rel/management/env.sh.eex` to expose `setup` and `migrate` release commands
without starting business services. Both use stock VM templates and neither has
an `overlays` subtree. The historical Store CLI under
`rel/overlays/` requires the retired combined `yellow_dog` release and is retained
as legacy source, not copied into either supported product.
