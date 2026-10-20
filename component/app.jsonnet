local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.registry_cache;
local argocd = import 'lib/argocd.libjsonnet';

local instance = inv.parameters._instance;
local app = argocd.App(instance, params.namespace, base='registry-cache') {
  spec+: {
    syncPolicy+: {
      syncOptions+: [
        'ServerSideApply=true',
      ],
    },
  },
};

local appPath =
  local project = std.get(std.get(app, 'spec', {}), 'project', 'syn');
  if project == 'syn' then 'apps' else 'apps-%s' % project;

{
  ['%s/%s' % [ appPath, instance ]]: app,
}
