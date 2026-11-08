@main struct Run {
    static func main() async {
        ownedControl()
        dynamicControl()
        await sharedTaskControl()
        await isolatedControl()
        print("G0: owned recovery, closed dispatch, lock submission, shared task, isolated task passed")
    }
}
