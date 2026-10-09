# Porting skill authoring to other stacks

Read this when the instructions will run somewhere other than Claude Code or the Agent Skills
surfaces.

- **Editor rules files.** These face the same problem of the description deciding selection, but
  most rules systems either always load or load by glob, so anti-triggers become a glob scope. Keep
  bodies short regardless, because always-loaded rules cost context on every request.
- **Custom system-prompt assembly.** Concatenating markdown files rebuilds level 2 without level 1.
  Build the metadata index yourself, from names and descriptions only, and load bodies on demand.
- **Retrieval layers over instructions.** Any framework that chunks or truncates instructions reads
  them partially, which is exactly what the 500-line and one-level-deep rules protect against.
- **Anywhere.** These are properties of how models consume instructions, not features of one
  product: third-person descriptions, use-when plus not-for, critical rules first, clarity about
  whether a file is run or read, and measuring before writing.
