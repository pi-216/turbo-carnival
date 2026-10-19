import { application } from "./application"
import VotingController from "./voting_controller"
import KillLeftController from "./kill_left_controller"
import MobileMenuController from "./mobile_menu_controller"
import WeightCalculatorController from "./weight_calculator_controller"

application.register("voting", VotingController)
application.register("kill-left", KillLeftController)
application.register("mobile-menu", MobileMenuController)
application.register("weight-calculator", WeightCalculatorController)
