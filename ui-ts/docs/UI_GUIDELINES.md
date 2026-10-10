# Partition workspace design

The partition workspace follows [Material 3 list-detail layout](https://m3.material.io/foundations/layout/canonical-examples/list-detail)
and [Nielsen Norman Group usability heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/).

- Keep partition names and capacities in the list; show actions for the selected
  partition in one detail pane. At compact widths, show one pane with a back action.
- Use familiar task labels: back up, choose image, review write. Explain that XML
  plans are an optional batch workflow.
- Show the exact destination and write range before an overwrite. Reject invalid
  images and stale device selections before starting the operation.
- Keep ongoing progress visible. Finished results are compact and dismissible,
  while the session log retains their details.
- Put low-frequency sector details behind an expandable disclosure. Preserve
  search context when returning from the detail pane.
