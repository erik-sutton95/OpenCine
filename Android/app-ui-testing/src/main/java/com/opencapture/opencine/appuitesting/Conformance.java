package com.opencapture.opencine.appuitesting;

import java.lang.annotation.ElementType;
import java.lang.annotation.Inherited;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Marks the kit's scenario classes. Inherited, so an app's one-line subclass carries it and CI selects
 * every conformance class with
 * {@code -Pandroid.testInstrumentationRunnerArguments.annotation=com.opencapture.opencine.appuitesting.Conformance}.
 * Java because a Kotlin annotation cannot be {@link Inherited}.
 */
@Inherited
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface Conformance {}
