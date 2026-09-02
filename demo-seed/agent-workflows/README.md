# agent-workflows

Catalog of agent workflows for this platform. Each chart is a self-service workflow a team can
deploy from the APL Console (Workloads -> Add New -> Select Catalog).

- **pr-agent** (team workload): on a pull request, forwards the event to the node broker, which
  spins up an ephemeral Turnstone agent node wired to the team's environment.
- **agent-node-broker** (admin workload, installed once): holds the only rights in the `turnstone`
  namespace; creates and destroys the ephemeral agent nodes on request.
