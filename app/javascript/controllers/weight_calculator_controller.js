import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["weight", "remaining", "bar"]
  static values = { 
    used: Number,
    current: Number,
    max: Number
  }

  connect() {
    this.updateDisplay()
  }

  updateDisplay() {
    const weight = parseFloat(this.weightTarget.value) || 0
    const available = this.maxValue - this.usedValue
    const remaining = available - weight
    
    this.remainingTarget.textContent = `${remaining.toFixed(2)}%`
    this.remainingTarget.classList.toggle('text-green-400', remaining >= 0)
    this.remainingTarget.classList.toggle('text-red-400', remaining < 0)
    
    const usedTotal = this.usedValue + weight
    const percentage = Math.min((usedTotal / this.maxValue) * 100, 100)
    this.barTarget.style.width = `${percentage}%`
    
    if (usedTotal > this.maxValue) {
      this.barTarget.classList.remove('bg-purple-600')
      this.barTarget.classList.add('bg-red-600')
    } else {
      this.barTarget.classList.remove('bg-red-600')
      this.barTarget.classList.add('bg-purple-600')
    }
  }
}
