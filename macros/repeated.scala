package macros

import scala.language.higherKinds

/** Boiler-plate to produce heterogenous lists where individual elements are processed using a view.
  * @tparam V the view bound: an implicit V[A] trait for individual arguments
  * @tparam B the result type of processing individual arguments through the view.
  * @tparam R the overall result type of aggregating all arguments, such as Seq[B]
  */
trait RepeatedView[V[_],B,R] {
  /** Function to process individual arguments. */
  protected def arg[A : V](a : A) : B
  /** Function to produce final results. */
  protected def result(b : B*) : R

  def apply() : R = result()
  def apply[A1 : V](a1 : A1) : R = result(arg(a1))
  def apply[A1 : V, A2 : V](a1 : A1, a2 : A2) : R = result(arg(a1), arg(a2))
}
