import UIKit

/// Presents a full-screen view controller by sliding it down from the top edge,
/// and dismisses it by sliding it back up (the inverse of the default cover).
final class SlideFromTopTransition: NSObject, UIViewControllerTransitioningDelegate {
    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return Animator(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return Animator(presenting: false)
    }

    private final class Animator: NSObject, UIViewControllerAnimatedTransitioning {
        private let presenting: Bool

        init(presenting: Bool) {
            self.presenting = presenting
        }

        func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
            return 0.35
        }

        func animateTransition(using context: UIViewControllerContextTransitioning) {
            let container = context.containerView
            let duration = transitionDuration(using: context)

            if presenting {
                guard let toView = context.view(forKey: .to),
                      let toVC = context.viewController(forKey: .to) else { return context.completeTransition(false) }
                let final = context.finalFrame(for: toVC)
                toView.frame = final.offsetBy(dx: 0, dy: -final.height)
                container.addSubview(toView)
                UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut, animations: {
                    toView.frame = final
                }, completion: { _ in
                    context.completeTransition(!context.transitionWasCancelled)
                })
            } else {
                guard let fromView = context.view(forKey: .from) else { return context.completeTransition(false) }
                // Full-screen presentation removed the presenter's view; put it back underneath.
                if let toView = context.view(forKey: .to) {
                    let final = context.viewController(forKey: .to).map { context.finalFrame(for: $0) } ?? .zero
                    toView.frame = final.isEmpty ? container.bounds : final
                    container.insertSubview(toView, belowSubview: fromView)
                }
                UIView.animate(withDuration: duration, delay: 0, options: .curveEaseIn, animations: {
                    fromView.frame = fromView.frame.offsetBy(dx: 0, dy: -fromView.frame.height)
                }, completion: { _ in
                    context.completeTransition(!context.transitionWasCancelled)
                })
            }
        }
    }
}
