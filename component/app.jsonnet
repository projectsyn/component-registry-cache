local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.registry_cache;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('registry-cache', params.namespace);

{
  'registry-cache': app,
}
