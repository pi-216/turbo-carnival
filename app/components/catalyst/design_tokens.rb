# frozen_string_literal: true

module Catalyst
  # Design tokens from Catalyst UI Kit
  # Reference: https://catalyst.tailwindui.com/docs
  module DesignTokens
    # Color palette
    COLORS = {
      # Primary semantic colors
      primary: "blue",
      danger: "red",
      success: "green",
      warning: "amber",
      info: "sky",

      # Button colors (subset of available)
      blue: "blue",
      red: "red",
      green: "green",
      zinc: "zinc",
      indigo: "indigo",
      amber: "amber",
      emerald: "emerald",
      cyan: "cyan",
      sky: "sky",
      violet: "violet",
      purple: "purple"
    }.freeze

    # Spacing scale for components
    SPACING = {
      tight: "gap-2",
      normal: "gap-4",
      relaxed: "gap-6",
      wide: "gap-8"
    }.freeze

    # Shadow system
    SHADOWS = {
      sm: "shadow-sm",
      default: "shadow",
      lg: "shadow-lg"
    }.freeze

    # Border radius
    RADIUS = {
      default: "rounded-lg",
      card: "rounded-xl",
      full: "rounded-full"
    }.freeze

    # Typography sizes (with line-height)
    TEXT_SIZES = {
      xs: "text-xs/4",
      sm: "text-sm/6",
      base: "text-base/6",
      lg: "text-lg/7",
      xl: "text-xl/8",
      "2xl": "text-2xl/8"
    }.freeze

    # Font weights
    FONT_WEIGHTS = {
      normal: "font-normal",
      medium: "font-medium",
      semibold: "font-semibold",
      bold: "font-bold"
    }.freeze
  end
end
