/** Remove only an exact synthetic console refusal captured inside its injection window.
 * Page exceptions, substring matches and earlier/later errors remain fatal in the shared fixture.
 */
export function retainUnexpectedErrors(errors: string[], expectedMessage: string, start: number, end: number): void {
  const expected = `console.error: ${expectedMessage}`;
  const unexpected = errors.filter((error, index) => !(index >= start && index < end && error === expected));
  errors.splice(0, errors.length, ...unexpected);
}
