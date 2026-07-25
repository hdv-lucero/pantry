import { Controller } from "@hotwired/stimulus"

// §4.1 — the quantity stepper. Stimulus does exactly the sprinkle it is for:
// nudge the number, wait for the clicking to stop, then hand the request to
// Turbo by submitting the form it is attached to. No fetch, no CSRF handling,
// no response parsing — the controller answers with a Turbo Stream that swaps
// the row back in.
export default class extends Controller {
  static targets = ["input"]
  static values = {
    delay: { type: Number, default: 400 },
    min: { type: Number, default: 0 },
    step: { type: Number, default: 1 }
  }

  disconnect() {
    clearTimeout(this.timeout)
  }

  increment() {
    this.stepBy(this.stepValue)
  }

  decrement() {
    this.stepBy(-this.stepValue)
  }

  // Debounced so holding down "+" is one PATCH, not eight.
  save() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.element.requestSubmit(), this.delayValue)
  }

  stepBy(amount) {
    const current = Number(this.inputTarget.value) || 0
    this.inputTarget.value = Math.max(this.minValue, current + amount)
    this.save()
  }
}
