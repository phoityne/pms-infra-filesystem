# pms-infra-filesystem

`pms-infra-filesystem` is one of the internal packages that make up the [`pty-mcp-server`](https://github.com/phoityne/pty-mcp-server) project.

`pms-infra-filesystem` is a package that executes scripts corresponding to tool names published in `tools-list.json`. When an MCP client requests a tool execution, this component locates the matching script, runs it with any given parameters, and returns the output to the client. It enables a flexible server-side tool execution model, allowing clients to trigger predefined commands dynamically without hardcoding logic on the client side. 

---

## Package Structure
![Package Structure](https://raw.githubusercontent.com/phoityne/pms-infra-filesystem/main/docs/01_package_structure.png)
---

## Module Structure
![Module Structure](https://raw.githubusercontent.com/phoityne/pms-infra-filesystem/main/docs/02_module_structure.png)

---
