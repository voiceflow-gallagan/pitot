import PitotCore

extension SettingsModel {
    func startOnboarding() {
        guard let setupQuestions else {
            errorMessage = setupQuestionsError ?? "The setup questions are not available."
            return
        }
        guard user.snapshot != nil, onboarding == nil else { return }
        onboarding = OnboardingModel(file: setupQuestions, settings: self)
    }

    /// Closes the questions. After the first time, they no longer open at launch.
    func finishOnboarding() {
        onboarding = nil
        launchFlags?.onboardingSeen = true
    }

    func presentOnboardingIfFirstLaunch() {
        guard let launchFlags, !launchFlags.onboardingSeen else { return }
        startOnboarding()
    }
}
