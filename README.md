# pms-infra-filesystem

`pms-infra-filesystem` is one of the internal packages that make up the PMS infrastructure.

`pms-infra-filesystem` provides file system operations as an Infra-layer component, isolating direct OS file access from the Domain and UseCase layers. It is responsible for validating permitted paths, performing safe file and directory operations, and converting file system data into structured representations suitable for JSON and MCP communication.

By centralizing path normalization, access control, and size checks, this package enables higher layers to interact with the file system through a controlled and secure interface, without depending on OS-specific details.


---

## Package Structure
![Package Structure](https://raw.githubusercontent.com/phoityne/pms-infra-filesystem/main/docs/01_package_structure.png)
---

## Module Structure
![Module Structure](https://raw.githubusercontent.com/phoityne/pms-infra-filesystem/main/docs/02_module_structure.png)

---
