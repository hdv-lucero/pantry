import { Controller } from "@hotwired/stimulus"

// §4.3 — the "I made this" modal. The <dialog> element does the actual work: the
// backdrop, the focus trap, and Esc-to-close are all native, so this is a sprinkle
// in the same sense the quantity stepper is — open it when Turbo renders it into
// the frame, and tidy up after it closes.
//
// Emptying the frame on close matters: the frame keeps whatever was last rendered
// into it, so without this the next "I made this" would flash the previous
// recipe's dialog before its own request came back.
export default class extends Controller {
  connect() {
    if (!this.element.open) this.element.showModal()
  }

  close() {
    this.element.close()
  }

  // Wired to the dialog's own close event, so it runs however the dialog was
  // closed — Cancel, Skip, or Esc. Optional, because answering the thumbs empties
  // the frame from the server instead, and a dialog closing on its way out of the
  // DOM has no frame left to tidy.
  clear() {
    this.element.closest("turbo-frame")?.replaceChildren()
  }
}
