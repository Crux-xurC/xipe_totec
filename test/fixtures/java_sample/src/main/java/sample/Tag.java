package sample;
public class Tag implements java.io.Serializable { public String text = ""; @Override public boolean equals(Object o) { return o instanceof Tag t && t.text.equals(text); } @Override public int hashCode() { return text.hashCode(); } }
