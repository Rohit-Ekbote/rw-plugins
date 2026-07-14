## External Neo4j not honored by agentfarm / usearch (chart bug — kit renders green, runs wrong)

**Symptom:** With `subcharts=byo-datastores` and an external Neo4j
(`neo4j.deploy: false`, `neo4j.external.uri` set), `agentfarm` and the three
`usearch` pods (indexer/query/worker) crash-loop or hang on startup, stuck on
`waiting for neo4j` — even though the operator pointed the platform at a working
external Neo4j.

**Cause (rwlight-helm chart, re-verified 2026-07-14 on chart 0.2.61; first seen
0.2.54):** only `templates/configmap.yaml` honors the external URI. Five
deployment templates **hardcode the bundled in-cluster Neo4j Service name**
regardless of `neo4j.deploy`:

- `templates/agentfarm/deployment.yaml` → `NEO4J_URI: "bolt://{{ .Values.neo4j.neo4j.name }}-lb-neo4j:7687"`
- `templates/usearch/indexer-deployment.yaml` → `GRAPH_DB_URI: "neo4j://…-lb-neo4j:7687"` (+ an `nc -z …-lb-neo4j` init wait)
- `templates/usearch/query-deployment.yaml` → same
- `templates/usearch/worker-deployment.yaml` → same
- `templates/usearch/neo4j-migration-controller.yaml` → same (added in the 0.2.x line; same hardcoded bundled host)

When `neo4j.deploy: false`, `<release>-neo4j-lb-neo4j` does not exist, so those
pods wait forever for a Service that will never come up. The generated values are
correct; the chart templates ignore them.

**Detection:** the wizard's value-at-consumer guard
(`tests/test-airgap-registry.sh`, byo profile) asserts the operator's `neo4jUri`
reaches **every** `NEO4J_URI`/`GRAPH_DB_URI` consumer. It fails here — by design —
surfacing the split: `configmap` gets the external URI while agentfarm/usearch get
the bundled one. This is a genuine red, not a plugin defect.

**Fix (out of the plugin's scope — belongs in rwlight-helm):** template the five
deployments off the same external-aware helper the configmap uses (e.g.
`runwhen.graphDbUri`) instead of hardcoding `…-lb-neo4j`. Until then, external
Neo4j is only partially supported.

**Workaround:** run bundled Neo4j (`subcharts=bundled-all`), or accept that
agentfarm/usearch will target the bundled Service name and provision Neo4j at
exactly `<release>-neo4j-lb-neo4j:7687` (defeats "external").

_Source: value-at-consumer check, first full run 2026-07-07; re-verified on chart 0.2.61 on 2026-07-14 (5th consumer added)._
