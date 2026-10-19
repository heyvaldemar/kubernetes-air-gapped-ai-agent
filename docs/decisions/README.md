# Decisions

Each record states the context, the decision, what it costs, what was considered instead, and how the choice would be explained to a customer.

| # | Decision | Status |
|---|---|---|
| 1 | [The boundary is the host's firewall, the node's resolver and CoreDNS](0001-the-boundary-is-the-runners-firewall.md) | accepted |
| 2 | [The registry inside has its own name and speaks only TLS](0002-the-registry-inside-has-its-own-name.md) | accepted |
| 3 | [Model weights as a signed image, mounted as an image volume](0003-model-weights-as-a-signed-image-volume.md) | accepted |
| 4 | [Small open-weights models on CPU, chosen by measurement](0004-small-models-on-cpu-chosen-by-measurement.md) | accepted |
| 5 | [Gate the boundary, measure the model](0005-gate-the-boundary-measure-the-model.md) | accepted |
| 6 | [Tools through the sandbox's MCP server, with arguments held by schema](0006-tools-through-the-sandboxs-mcp-server.md) | accepted |
| 7 | [Every model through the same boundary, every day](0007-every-model-through-the-same-boundary.md) | accepted |
| 8 | [One signed file across the gap](0008-one-signed-file-across-the-gap.md) | accepted |
| 9 | [An AI-BOM for every model, read at admission](0009-an-ai-bom-for-every-model.md) | accepted |
| 10 | [One gateway in front of the models](0010-one-gateway-in-front-of-the-models.md) | accepted, amended by 11 |
| 11 | [The gateway knows who is calling](0011-the-gateway-knows-who-is-calling.md) | accepted |
